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
    /// Flattened directory name → resolved checkout, remembered for a while.
    /// Resolving probes the file system once per `-` in the name, for every
    /// project directory, on every 2 s pass. An answer that read every `-` as
    /// a path separator is the preferred reading and can only stop being true
    /// by deletion, which `resolveTTL` bounds. A miss, and a path that folded
    /// a hyphen into a component (which a directory created later would
    /// outrank), are kept for `unsettledTTL` only.
    private var projectPaths: [String: (path: String?, at: Date, settled: Bool)] = [:]
    static let resolveTTL: TimeInterval = 600
    static let unsettledTTL: TimeInterval = 60

    private func discover(now: Date) -> [CursorTranscripts.Located] {
        var fresh: [String: (path: String?, settled: Bool)] = [:]
        let located = CursorTranscripts.discover(root: root) { [projectPaths] name in
            if let cached = projectPaths[name],
               now.timeIntervalSince(cached.at) < (cached.settled ? Self.resolveTTL : Self.unsettledTTL) {
                return cached.path
            }
            let path = CursorTranscripts.projectPath(forDirectoryName: name)
            fresh[name] = (path, path.map { Self.isSeparatorOnly(name: name, path: $0) } ?? false)
            return path
        }
        for (name, answer) in fresh { projectPaths[name] = (answer.path, now, answer.settled) }
        return located
    }

    /// Every `-` in the name became a `/`: the components count matches.
    static func isSeparatorOnly(name: String, path: String) -> Bool {
        name.split(separator: "-", omittingEmptySubsequences: false).count
            == path.split(separator: "/", omittingEmptySubsequences: false).dropFirst().count
    }

    /// How often a pass runs with no file-system event at all: the safety net
    /// under the event stream. Without a stream, passes run every `interval`.
    private let quietInterval: Duration

    public init(root: URL = CursorTranscripts.projectsRoot(),
                interval: Duration = .seconds(2),
                quietInterval: Duration = .seconds(30)) {
        self.root = root
        self.interval = interval
        self.quietInterval = quietInterval
    }

    /// The transcript vibebuddy is tailing for this conversation, for
    /// `/recent-output`.
    public func transcriptPath(for sessionID: String) -> String? {
        pathsBySession[sessionID]
    }

    /// Only transcript writes wake the tail. Project directories also hold
    /// `worker.log`, terminal captures and MCP state that Cursor rewrites
    /// constantly while it is open.
    static func isTranscriptPath(_ path: String) -> Bool {
        path.split(separator: "/").contains("agent-transcripts")
    }

    /// Passes run when a transcript changes, at most one per `interval` —
    /// the old fixed cadence, so a busy conversation costs no more than it
    /// did and the first line after a quiet spell is seen at once. With
    /// nothing changing, a pass runs every `quietInterval` only.
    public func run(store: SessionStore) async {
        let (wakes, wake) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        let events = DirectoryEventStream(root: root, relevant: Self.isTranscriptPath) { wake.yield() }
        let ticker = events.map { _ in
            Task { [quietInterval] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: quietInterval) } catch { return }
                    wake.yield()
                }
            }
        }
        defer {
            ticker?.cancel()
            events?.stop()
            wake.finish()
        }
        // Establish cursors without emitting: everything already on disk is
        // history, and history is the composer store's job. The stream is
        // already open, so a line written meanwhile wakes the first pass.
        _ = seed(now: Date())
        var pending = wakes.makeAsyncIterator()
        while !Task.isCancelled {
            // Without the stream, every `interval` as before.
            if events != nil, await pending.next() == nil { return }
            for event in poll(now: Date()) {
                await store.ingest(event)
            }
            do { try await Task.sleep(for: interval) } catch { return }
        }
    }

    /// Register every transcript at its current end, emitting nothing.
    /// Returns how many files are now being tailed (for tests and diagnostics).
    @discardableResult
    public func seed(now: Date) -> Int {
        for located in discover(now: now) {
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
        for located in discover(now: now).reversed() {
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
                for line in CursorTranscripts.parse(line: String(raw), fullContent: true) {
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
        case .toolUse(let name, let detail):
            var observed = base(cursor, kind: .preToolUse, at: now,
                                tool: CursorToolVocabulary.canonicalTool(name))
            observed.toolCall = ToolCallRecord(id: UUID().uuidString, tool: name,
                command: ToolActivity.phrase(for: name) == "Running" ? detail : nil,
                observedAt: now, source: "transcript",
                coverage: "Cursor transcript intent only; no result or exit code is recorded")
            return observed
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
