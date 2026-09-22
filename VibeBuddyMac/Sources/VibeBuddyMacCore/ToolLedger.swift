import Foundation
import VibeBuddyKit

/// Separate bounded journal sidecar. Unlike LifecycleJournal this
/// explicitly contains bounded commands/paths, but never full output or prompts.
struct ToolLedger: Sendable {
    private(set) var sessions: [String: [ToolCallRecord]] = [:]
    private let url: URL?
    private var persistencePending = false
    /// The whole sidecar is re-encoded on every write, and an agent mid-task
    /// observes several tool calls a second; one write per window is enough
    /// for a recovery aid. A change inside the window is written by the next
    /// `prune(now:)` (every snapshot) or the next observation after it.
    static let writeInterval: TimeInterval = 2
    /// Monotonic: the caller's `now` is an event timestamp (hook receipt, a
    /// rollout line's own clock) and may run backwards during catch-up; it
    /// bounds the retention window, never the write anchor.
    private var lastWriteAt: ContinuousClock.Instant?
    /// True while a change is waiting for the window to pass. The owner arms
    /// a trailing `prune` from it so a headless daemon or a quiet app does
    /// not sit on an unwritten tail.
    var needsTrailingWrite: Bool { persistencePending && url != nil }
    /// Files actually written. Exposed for tests.
    private(set) var writeCount = 0
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
        let retained = Array(records.suffix(50))
        guard retained != sessions[sessionID] else {
            if pruneRetained(now: now) || persistencePending { persist(now: now) }
            return
        }
        sessions[sessionID] = retained
        _ = pruneRetained(now: now)
        persist(now: now)
    }
    mutating func prune(now: Date) {
        // Expiry is rare and must not linger on disk: it writes through the window.
        if pruneRetained(now: now) { persist(now: now, force: true) }
        else if persistencePending { persist(now: now) }
    }
    /// Write whatever the window is still holding back, now. The sidecar is
    /// what a reader in another process (the handoff facts tool) sees, so a
    /// caller that is about to hand the file over — or a test that wrote a
    /// fixture — must not depend on the trailing write having happened yet.
    mutating func flush(now: Date) {
        _ = pruneRetained(now: now)
        if persistencePending { persist(now: now, force: true) }
    }
    private mutating func pruneRetained(now: Date) -> Bool {
        let previous = sessions
        let cutoff = now.addingTimeInterval(-7 * 86400)
        sessions = sessions.mapValues { Array($0.filter { $0.observedAt >= cutoff }.suffix(50)) }.filter { !$0.value.isEmpty }
        let retained = Set(sessions.sorted { ($0.value.last?.observedAt ?? .distantPast) > ($1.value.last?.observedAt ?? .distantPast) }.prefix(250).map(\.key))
        sessions = sessions.filter { retained.contains($0.key) }
        return sessions != previous
    }
    mutating func clear() -> Bool {
        if let url, FileManager.default.fileExists(atPath: url.path) {
            do { try FileManager.default.removeItem(at: url) } catch { return false }
        }
        sessions = [:]
        persistencePending = false
        lastWriteAt = nil
        return true
    }
    private mutating func persist(now: Date, force: Bool = false) {
        persistencePending = url != nil
        if !force, let last = lastWriteAt, ContinuousClock.now - last < .seconds(Self.writeInterval) { return }
        // Bound the entire sidecar as well as each session. Drop oldest sessions
        // before serializing beyond the read cap; retained scope is shown in UI.
        guard var data = try? JSONEncoder().encode(sessions) else { return }
        while sessions.count > 1, data.count > 8_000_000 {
            guard let oldest = sessions.min(by: { ($0.value.last?.observedAt ?? .distantPast) < ($1.value.last?.observedAt ?? .distantPast) })?.key else { break }
            sessions[oldest] = nil
            guard let trimmed = try? JSONEncoder().encode(sessions) else { return }
            data = trimmed
        }
        guard let url else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            persistencePending = false
            lastWriteAt = .now  // a failed write keeps the window open for the retry
            writeCount += 1
        } catch {}
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
