import Foundation
import VibeBuddyKit

/// Tails Cursor's agent transcripts so a Cursor conversation is visible even
/// when vibebuddy's hooks are not installed — and so the part of the lifecycle
/// the Cursor CLI does not yet hook (`beforeSubmitPrompt`, `afterAgentResponse`)
/// still reaches the three states.
///
/// Deliberately a *tail*, not an importer: a transcript first seen on this pass
/// starts at end-of-file and produces no events, so starting vibebuddy never
/// replays yesterday's turns as completions to acknowledge. Existing
/// conversations arrive through `CursorComposerStore` instead, which knows their
/// real status. Only bytes appended while vibebuddy is watching become events.
///
/// Read-only throughout: the monitor opens transcripts for reading and never
/// writes into Cursor's directories.
public actor CursorTranscriptMonitor {
    /// Where one transcript has been read up to.
    struct Cursor {
        var offset: UInt64
        var conversationID: String
        var project: String?
        var path: String
        /// Carried so a `stop` can say what the turn produced without re-reading.
        var lastAssistantText: String?
    }

    private let root: URL
    private let interval: Duration
    private var cursors: [String: Cursor] = [:]   // keyed by file path
    private var pathsBySession: [String: String] = [:]

    public init(root: URL = CursorTranscripts.projectsRoot(),
                interval: Duration = .seconds(2)) {
        self.root = root
        self.interval = interval
    }

    /// The transcript vibebuddy is tailing for this conversation, for
    /// `/recent-output`.
    public func transcriptPath(for sessionID: String) -> String? {
        pathsBySession[sessionID]
    }

    public func run(store: SessionStore) async {
        // Establish cursors without emitting: everything already on disk is
        // history, and history is the composer store's job.
        _ = seed(now: Date())
        while !Task.isCancelled {
            do { try await Task.sleep(for: interval) } catch { return }
            for event in poll(now: Date()) {
                await store.ingest(event)
            }
        }
    }

    /// Register every transcript at its current end, emitting nothing.
    /// Returns how many files are now being tailed (for tests and diagnostics).
    @discardableResult
    public func seed(now: Date) -> Int {
        for located in CursorTranscripts.discover(root: root) {
            guard cursors[located.url.path] == nil else { continue }
            cursors[located.url.path] = Cursor(
                offset: UInt64(max(0, located.size)),
                conversationID: located.conversationID,
                project: located.project,
                path: located.url.path)
            pathsBySession[located.conversationID] = located.url.path
        }
        return cursors.count
    }

    /// One deterministic pass: pick up newly appended lines (and newly created
    /// transcripts, from their first byte) and turn them into events.
    public func poll(now: Date) -> [HookEvent] {
        var events: [HookEvent] = []
        for located in CursorTranscripts.discover(root: root).reversed() {
            let key = located.url.path
            var cursor = cursors[key] ?? Cursor(
                offset: 0, conversationID: located.conversationID,
                project: located.project, path: key)
            // A file that shrank was replaced or truncated; start over.
            if UInt64(max(0, located.size)) < cursor.offset { cursor.offset = 0 }
            cursor.project = located.project ?? cursor.project
            pathsBySession[located.conversationID] = key
            guard UInt64(located.size) > cursor.offset else {
                cursors[key] = cursor
                continue
            }
            let (data, consumed) = Self.read(path: key, from: cursor.offset)
            cursor.offset += consumed
            for raw in String(decoding: data, as: UTF8.self)
                .split(separator: "\n", omittingEmptySubsequences: true) {
                for line in CursorTranscripts.parse(line: String(raw)) {
                    if let event = Self.event(for: line, cursor: &cursor, at: now) {
                        events.append(event)
                    }
                }
            }
            cursors[key] = cursor
        }
        return events
    }

    /// One transcript line as a lifecycle event.
    ///
    /// A tool call is a `preToolUse` and nothing clears it here: the transcript
    /// records no tool *results*, so the only honest end of a tool is the next
    /// line or the turn's end, both of which the reducer already handles.
    static func event(for line: CursorTranscripts.Line, cursor: inout Cursor,
                      at now: Date) -> HookEvent? {
        switch line {
        case .prompt(let text):
            cursor.lastAssistantText = nil
            return base(cursor, kind: .userPromptSubmit, at: now,
                        message: text.isEmpty ? nil : text)
        case .assistantText(let text):
            cursor.lastAssistantText = text
            return base(cursor, kind: .sessionMetadataChanged, at: now,
                        message: String(text.prefix(220)))
        case .toolUse(let name, _):
            return base(cursor, kind: .preToolUse, at: now,
                        tool: CursorToolVocabulary.canonicalTool(name))
        case .turnEnded(let status, let error):
            let message: String? = status == "success"
                ? cursor.lastAssistantText.map { String($0.prefix(220)) }
                : (error ?? (status == "aborted" ? "Turn stopped" : "Turn failed"))
            let event = base(cursor, kind: .stop, at: now, message: message,
                             completionText: status == "success" ? cursor.lastAssistantText : nil,
                             completionSucceeded: status == "success")
            // Cursor names an abort explicitly, so it is an ending the person
            // asked for rather than a break — the same distinction the hook
            // adapter makes for `stop.status == "aborted"`.
            return status == "aborted" ? event.markingUserStop() : event
        }
    }

    private static func base(_ cursor: Cursor, kind: HookEvent.Kind, at now: Date,
                             tool: String? = nil, message: String? = nil,
                             completionText: String? = nil,
                             completionSucceeded: Bool? = nil) -> HookEvent {
        HookEvent(kind: kind, sessionID: cursor.conversationID, agent: .cursor,
                  cwd: cursor.project, toolName: tool, message: message,
                  transcriptPath: cursor.path,
                  observationSource: .transcript, timestamp: now,
                  completionText: completionText, completionSucceeded: completionSucceeded)
    }

    /// Read from `offset` to end. Returns the bytes up to the last complete
    /// line, so a half-written line is re-read whole on the next pass.
    static func read(path: String, from offset: UInt64) -> (Data, UInt64) {
        guard let handle = FileHandle(forReadingAtPath: path) else { return (Data(), 0) }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: offset)
            let data = try handle.readToEnd() ?? Data()
            guard let lastNewline = data.lastIndex(of: 0x0A) else { return (Data(), 0) }
            let complete = data[data.startIndex...lastNewline]
            return (Data(complete), UInt64(complete.count))
        } catch {
            return (Data(), 0)
        }
    }
}
