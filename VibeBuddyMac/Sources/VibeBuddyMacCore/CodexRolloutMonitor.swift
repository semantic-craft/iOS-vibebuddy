import Foundation
import VibeBuddyKit

/// Pure, incremental decoder for Codex rollout JSONL. Codex Desktop writes this
/// stream even though it does not execute the user's CLI hooks, making it the
/// authoritative local fallback for desktop task progress.
public struct CodexRolloutParser: Sendable {
    public private(set) var sessionID: String?
    public private(set) var cwd: String?
    public private(set) var isDesktopSession = false
    public private(set) var turnActive = false
    private var activeTurnIDs: Set<String> = []
    private var anonymousTurnCount = 0

    public init() {}

    public mutating func parseLine(_ data: Data, receivedAt: Date) -> HookEvent? {
        guard Self.mightAffectProgress(data) else { return nil }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let recordType = root["type"] as? String,
              let payload = root["payload"] as? [String: Any]
        else { return nil }

        let timestamp = Self.timestamp(root["timestamp"] as? String) ?? receivedAt

        if recordType == "session_meta" {
            sessionID = payload["id"] as? String
            cwd = payload["cwd"] as? String
            let originator = (payload["originator"] as? String)?.lowercased()
            let source = (payload["source"] as? String)?.lowercased()
            isDesktopSession = originator == "codex desktop" || source == "vscode"
            return nil
        }

        guard let sessionID, isDesktopSession else { return nil }

        if recordType == "event_msg", let eventType = payload["type"] as? String {
            switch eventType {
            case "task_started":
                startTurn(payload["turn_id"] as? String)
                return event(.userPromptSubmit, sessionID: sessionID, timestamp: timestamp)
            case "task_complete":
                finishTurn(payload["turn_id"] as? String)
                guard !turnActive else { return nil }
                return event(.stop, sessionID: sessionID,
                             message: payload["last_agent_message"] as? String,
                             timestamp: timestamp)
            case "turn_aborted":
                finishTurn(payload["turn_id"] as? String)
                guard !turnActive else { return nil }
                return event(.stop, sessionID: sessionID,
                             message: "Turn aborted", timestamp: timestamp)
            case "exec_approval_request":
                return event(.notification, sessionID: sessionID, toolName: "Shell",
                             message: "Permission required for Shell", timestamp: timestamp)
            case "apply_patch_approval_request":
                return event(.notification, sessionID: sessionID, toolName: "File change",
                             message: "Permission required for file change", timestamp: timestamp)
            case "request_user_input", "elicitation_request":
                return event(.notification, sessionID: sessionID,
                             message: "Waiting for your input", timestamp: timestamp)
            case "item_completed":
                guard let item = payload["item"] as? [String: Any],
                      let toolName = Self.completedToolName(item) else { return nil }
                return event(.postToolUse, sessionID: sessionID,
                             toolName: toolName,
                             toolError: Self.itemFailed(item),
                             timestamp: timestamp)
            default:
                return nil
            }
        }

        if recordType == "response_item", let itemType = payload["type"] as? String {
            if Self.toolCallTypes.contains(itemType) {
                let name = Self.startedToolName(payload, itemType: itemType)
                if name.split(separator: "/").last?.lowercased() == "request_user_input" {
                    return event(.notification, sessionID: sessionID, toolName: name,
                                 message: "Waiting for your input", timestamp: timestamp)
                }
                return event(.preToolUse, sessionID: sessionID,
                             toolName: name, timestamp: timestamp)
            }
            if Self.toolOutputTypes.contains(itemType) {
                return event(.postToolUse, sessionID: sessionID,
                             toolName: "Tool", timestamp: timestamp)
            }
            if itemType == "message", payload["phase"] as? String == "final_answer" {
                finishUnknownTurn()
                guard !turnActive else { return nil }
                return event(.stop, sessionID: sessionID, timestamp: timestamp)
            }
        }

        return nil
    }

    private func event(
        _ kind: HookEvent.Kind,
        sessionID: String,
        toolName: String? = nil,
        message: String? = nil,
        toolError: Bool = false,
        timestamp: Date
    ) -> HookEvent {
        HookEvent(kind: kind, sessionID: sessionID, agent: .codex,
                  cwd: cwd, toolName: toolName, message: message,
                  toolError: toolError, timestamp: timestamp)
    }

    private static let toolCallTypes: Set<String> = [
        "function_call", "custom_tool_call", "local_shell_call", "mcp_tool_call",
    ]

    private static let toolOutputTypes: Set<String> = [
        "function_call_output", "custom_tool_call_output", "local_shell_call_output",
    ]

    /// Rollouts contain large reasoning, message, and tool-output records. Avoid
    /// decoding records that cannot change the three-state session model.
    private static func mightAffectProgress(_ data: Data) -> Bool {
        progressMarkers.contains { data.range(of: $0) != nil }
    }

    private static let progressMarkers: [Data] = [
            #""type":"session_meta""#,
            #""type":"task_started""#,
            #""type":"task_complete""#,
            #""type":"turn_aborted""#,
            #""type":"exec_approval_request""#,
            #""type":"apply_patch_approval_request""#,
            #""type":"request_user_input""#,
            #""type":"elicitation_request""#,
            #""type":"item_completed""#,
            #""type":"function_call""#,
            #""type":"custom_tool_call""#,
            #""type":"local_shell_call""#,
            #""type":"mcp_tool_call""#,
            #""type":"function_call_output""#,
            #""type":"custom_tool_call_output""#,
            #""type":"local_shell_call_output""#,
            #""phase":"final_answer""#,
        ].map { Data($0.utf8) }

    private static func startedToolName(_ payload: [String: Any], itemType: String) -> String {
        let name = (payload["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let namespace = (payload["namespace"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts: [String] = [namespace, name].compactMap { $0 }.filter { !$0.isEmpty }
        if !parts.isEmpty { return parts.joined(separator: "/") }
        return itemType == "local_shell_call" ? "Shell" : "Tool"
    }

    private static func completedToolName(_ item: [String: Any]) -> String? {
        guard let type = item["type"] as? String else { return nil }
        switch type {
        case "CommandExecution": return "Shell"
        case "McpToolCall":
            let server = item["server"] as? String
            let tool = item["tool"] as? String
            let target = [server, tool].compactMap { $0 }.joined(separator: "/")
            return target.isEmpty ? "MCP" : "MCP: \(target)"
        case "FileChange": return "File change"
        case "Extension":
            return (item["action_name"] as? String).map { "Extension: \($0)" } ?? "Extension"
        case "ContextCompaction": return "Context compaction"
        case "FunctionCallOutput": return "Tool"
        case "CollabAgentToolCall":
            return (item["tool"] as? String).map { "collaboration/\($0)" } ?? "Collaboration"
        case "ImageView": return "view_image"
        default: return nil
        }
    }

    private mutating func startTurn(_ turnID: String?) {
        if let turnID, !turnID.isEmpty { activeTurnIDs.insert(turnID) }
        else { anonymousTurnCount += 1 }
        refreshTurnState()
    }

    private mutating func finishTurn(_ turnID: String?) {
        if let turnID, !turnID.isEmpty {
            activeTurnIDs.remove(turnID)
        } else if anonymousTurnCount > 0 {
            anonymousTurnCount -= 1
        } else if activeTurnIDs.count == 1 {
            activeTurnIDs.removeAll()
        }
        refreshTurnState()
    }

    private mutating func finishUnknownTurn() {
        if anonymousTurnCount > 0 { anonymousTurnCount -= 1 }
        else if activeTurnIDs.count == 1 { activeTurnIDs.removeAll() }
        refreshTurnState()
    }

    private mutating func refreshTurnState() {
        turnActive = anonymousTurnCount > 0 || !activeTurnIDs.isEmpty
    }

    private static func itemFailed(_ item: [String: Any]) -> Bool {
        if let exit = item["exit_code"] as? NSNumber, exit.intValue != 0 { return true }
        if let status = (item["status"] as? String)?.lowercased(),
           ["failed", "error", "cancelled", "canceled", "interrupted"].contains(status) {
            return true
        }
        return item["error"] != nil
    }

    private static func timestamp(_ value: String?) -> Date? {
        guard let value else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }
        return ISO8601DateFormatter().date(from: value)
    }
}

/// Watches today's and yesterday's Codex rollout files and emits only appended
/// desktop lifecycle events. First discovery restores a currently active turn
/// without replaying old completions, preventing a dashboard full of stale work.
public actor CodexRolloutMonitor {
    private struct Cursor: Sendable {
        var offset: UInt64 = 0
        var remainder = Data()
        var parser = CodexRolloutParser()

        mutating func consume(_ data: Data, receivedAt: Date) -> [HookEvent] {
            remainder.append(data)
            var events: [HookEvent] = []
            var lineStart = remainder.startIndex
            while let newline = remainder[lineStart...].firstIndex(of: 0x0A) {
                if newline > lineStart {
                    let line = Data(remainder[lineStart..<newline])
                    if let event = parser.parseLine(line, receivedAt: receivedAt) {
                        events.append(event)
                    }
                }
                lineStart = remainder.index(after: newline)
                if lineStart == remainder.endIndex { break }
            }
            remainder = lineStart < remainder.endIndex
                ? Data(remainder[lineStart..<remainder.endIndex]) : Data()
            return events
        }
    }

    private let root: URL
    private let pollInterval: Duration
    private let recoveryWindow: TimeInterval
    private var cursors: [String: Cursor] = [:]

    public init(
        root: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/sessions", isDirectory: true),
        pollInterval: Duration = .seconds(1),
        recoveryWindow: TimeInterval = 30 * 60
    ) {
        self.root = root
        self.pollInterval = pollInterval
        self.recoveryWindow = recoveryWindow
    }

    public func run(store: SessionStore) async {
        while !Task.isCancelled {
            for event in poll(now: Date()) {
                await store.ingest(event)
            }
            do { try await Task.sleep(for: pollInterval) }
            catch { return }
        }
    }

    /// One deterministic polling pass, public so the file-tail contract can be
    /// tested without timers or a running HTTP server.
    public func poll(now: Date) -> [HookEvent] {
        let files = candidateFiles(now: now)
        let livePaths = Set(files.map(\.path))
        cursors = cursors.filter { livePaths.contains($0.key) }
        var emitted: [HookEvent] = []

        for file in files {
            let path = file.path
            let size = Self.fileSize(file)
            if var cursor = cursors[path] {
                if size < cursor.offset { cursor = Cursor() }
                guard size > cursor.offset,
                      let appended = Self.read(file, from: cursor.offset) else {
                    cursors[path] = cursor
                    continue
                }
                cursor.offset += UInt64(appended.count)
                emitted.append(contentsOf: cursor.consume(appended, receivedAt: now))
                cursors[path] = cursor
            } else {
                var cursor = Cursor()
                guard let contents = try? Data(contentsOf: file) else { continue }
                cursor.offset = UInt64(contents.count)
                let history = cursor.consume(contents, receivedAt: now)
                if cursor.parser.isDesktopSession, cursor.parser.turnActive,
                   let latest = history.last(where: { $0.kind != .stop && $0.kind != .sessionEnd }) {
                    emitted.append(latest)
                }
                cursors[path] = cursor
            }
        }
        return emitted
    }

    private func candidateFiles(now: Date) -> [URL] {
        let fm = FileManager.default
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        var files: [URL] = []

        for daysAgo in 0...1 {
            guard let day = calendar.date(byAdding: .day, value: -daysAgo, to: now) else { continue }
            let parts = calendar.dateComponents([.year, .month, .day], from: day)
            guard let year = parts.year, let month = parts.month, let dayNumber = parts.day else { continue }
            let directory = root
                .appendingPathComponent(String(format: "%04d", year), isDirectory: true)
                .appendingPathComponent(String(format: "%02d", month), isDirectory: true)
                .appendingPathComponent(String(format: "%02d", dayNumber), isDirectory: true)
            guard let entries = try? fm.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            files.append(contentsOf: entries.filter {
                guard $0.lastPathComponent.hasPrefix("rollout-"), $0.pathExtension == "jsonl",
                      let values = try? $0.resourceValues(forKeys: [.contentModificationDateKey]),
                      let modified = values.contentModificationDate else { return false }
                return now.timeIntervalSince(modified) <= recoveryWindow
            })
        }
        // Once tracked, retain a rollout even after the recovery window so a
        // long-running quiet turn is not dropped between polls.
        for path in cursors.keys where fm.fileExists(atPath: path) {
            let url = URL(fileURLWithPath: path)
            if !files.contains(url) { files.append(url) }
        }
        return files.sorted { $0.path < $1.path }
    }

    private static func fileSize(_ file: URL) -> UInt64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: file.path)
        return (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
    }

    private static func read(_ file: URL, from offset: UInt64) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: offset)
            return try handle.readToEnd() ?? Data()
        } catch {
            return nil
        }
    }
}
