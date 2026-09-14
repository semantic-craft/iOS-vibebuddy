import Foundation
import VibeBuddyKit

/// Separate bounded journal sidecar. Unlike LifecycleJournal this
/// explicitly contains bounded commands/paths, but never full output or prompts.
struct ToolLedger: Sendable {
    private(set) var sessions: [String: [ToolCallRecord]] = [:]
    private let url: URL?
    init(url: URL?, now: Date) {
        self.url = url
        if let url, let data = try? Data(contentsOf: url), data.count <= 8_000_000,
           let stored = try? JSONDecoder().decode([String: [ToolCallRecord]].self, from: data) { sessions = stored }
        prune(now: now)
    }
    mutating func observe(_ input: ToolCallRecord, sessionID: String, now: Date, agent: AgentKind? = nil) {
        var record = input
        record.agent = agent ?? input.agent
        var records = sessions[sessionID] ?? []
        if let index = records.firstIndex(where: { $0.id == record.id && $0.source == record.source && $0.agent == record.agent }) {
            let old = records[index]
            // Replayed intent must not erase a confirmed result.
            if old.result != .unconfirmed && record.result == .unconfirmed { return }
            var merged = record
            merged.command = record.command ?? old.command
            merged.files = Array(Set(old.files + record.files)).sorted()
            merged.linesAdded = record.linesAdded ?? old.linesAdded
            merged.linesRemoved = record.linesRemoved ?? old.linesRemoved
            records[index] = merged
        } else { records.append(record) }
        sessions[sessionID] = Array(records.suffix(50))
        prune(now: now)
        persist()
    }
    mutating func prune(now: Date) {
        let previous = sessions
        let cutoff = now.addingTimeInterval(-7 * 86400)
        sessions = sessions.mapValues { Array($0.filter { $0.observedAt >= cutoff }.suffix(50)) }.filter { !$0.value.isEmpty }
        let retained = Set(sessions.sorted { ($0.value.last?.observedAt ?? .distantPast) > ($1.value.last?.observedAt ?? .distantPast) }.prefix(250).map(\.key))
        sessions = sessions.filter { retained.contains($0.key) }
        if sessions != previous { persist() }
    }
    mutating func clear() -> Bool {
        if let url, FileManager.default.fileExists(atPath: url.path) {
            do { try FileManager.default.removeItem(at: url) } catch { return false }
        }
        sessions = [:]
        return true
    }
    private mutating func persist() {
        // Bound the entire sidecar as well as each session. Drop oldest sessions
        // before serializing beyond the read cap; retained scope is shown in UI.
        while sessions.count > 1, let data = try? JSONEncoder().encode(sessions), data.count > 8_000_000 {
            guard let oldest = sessions.min(by: { ($0.value.last?.observedAt ?? .distantPast) < ($1.value.last?.observedAt ?? .distantPast) })?.key else { break }
            sessions[oldest] = nil
        }
        guard let url, let data = try? JSONEncoder().encode(sessions) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    func applying(to input: AgentSession) -> AgentSession {
        var session = input
        let records = sessions[input.id] ?? []
        session.ledger = Array(records.suffix(20))
        let confirmed = records.filter { $0.result == .succeeded
            && (ToolActivity.phrase(for: $0.tool) == "Editing" || $0.tool.lowercased() == "patch") }
        session.changedFiles = Array(Set(confirmed.flatMap(\.files))).sorted()
        session.linesAdded = confirmed.contains { $0.linesAdded == nil } ? nil : confirmed.compactMap(\.linesAdded).reduce(0, +)
        session.linesRemoved = confirmed.contains { $0.linesRemoved == nil } ? nil : confirmed.compactMap(\.linesRemoved).reduce(0, +)
        session.commandsRun = records.filter { $0.command != nil && $0.result != .unconfirmed }.count
        return session
    }

    static func hook(_ data: Data, event: HookEvent) -> ToolCallRecord? {
        guard event.kind == .preToolUse || event.kind == .postToolUse, event.childID == nil,
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let input = raw["tool_input"] as? [String: Any] ?? [:]
        let response = raw["tool_response"] as? [String: Any] ?? [:]
        let id = raw["tool_use_id"] as? String ?? raw["tool_call_id"] as? String
        let hasResult = event.kind == .postToolUse && (event.toolError || raw["tool_response"] != nil || raw["tool_output"] != nil || raw["output"] != nil)
        let old = input["old_string"] as? String
        let new = input["new_string"] as? String ?? input["content"] as? String
        return ToolCallRecord(id: id ?? UUID().uuidString, tool: event.toolName ?? "Tool",
            command: input["command"] as? String ?? raw["command"] as? String,
            files: [input["file_path"] as? String ?? input["path"] as? String].compactMap { $0 },
            linesAdded: new.map { $0.isEmpty ? 0 : $0.split(separator: "\n", omittingEmptySubsequences: false).count },
            linesRemoved: old.map { $0.isEmpty ? 0 : $0.split(separator: "\n", omittingEmptySubsequences: false).count },
            result: hasResult ? (event.toolError ? .failed : .succeeded) : .unconfirmed,
            exitCode: response["exit_code"] as? Int ?? raw["exit_code"] as? Int,
            observedAt: event.timestamp, source: "hook",
            coverage: id == nil ? "No call identity; result cannot be linked to intent" : "Observed hook calls only; retained 50, snapshot 20")
    }
}
