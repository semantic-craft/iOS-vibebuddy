import Foundation
import VibeBuddyKit

/// Pure reducer: folds a stream of `HookEvent`s into the current set of
/// `AgentSession`s. No I/O and no `Date()` — time comes from the events — so it
/// is fully deterministic and unit-testable. Transcript/git enrichment (model,
/// tokens, branch) is layered on by the server, not here.
public struct SessionReducer: Sendable {
    public private(set) var sessions: [String: AgentSession] = [:]

    public init() {}

    public mutating func apply(_ event: HookEvent) {
        switch event.kind {
        case .sessionStart, .userPromptSubmit, .preToolUse, .postToolUse:
            // Active work: a tool starting/finishing means the agent is busy,
            // which also clears any prior "needs you" wait state.
            upsert(event, status: .working, waitKind: nil)
        case .notification:
            // The purpose-built "Claude wants your attention" signal.
            upsert(event, status: .needsResponse,
                   waitKind: Self.waitKind(from: event.message),
                   summary: event.message)
        case .stop:
            transition(event, to: .done)
        }
    }

    /// Layer transcript-derived metadata onto an existing session. Model and
    /// token usage always apply; the prose summary only applies when the session
    /// is not waiting on the user (so a permission/question prompt isn't clobbered).
    public mutating func enrich(sessionID: String, with info: TranscriptInfo) {
        guard var s = sessions[sessionID] else { return }
        if let model = info.model { s.model = model }
        if let tokens = info.tokens { s.tokens = tokens }
        if let summary = info.summary, s.status != .needsResponse { s.summary = summary }
        sessions[sessionID] = s
    }

    /// A sorted snapshot for broadcast: most-urgent first, then most-recent.
    public func snapshot(now: Date) -> Snapshot {
        let sorted = sessions.values.sorted { a, b in
            if a.status.attentionRank != b.status.attentionRank {
                return a.status.attentionRank < b.status.attentionRank
            }
            return a.updatedAt > b.updatedAt
        }
        return Snapshot(sessions: sorted, serverTime: now)
    }

    // MARK: - Helpers

    private mutating func upsert(
        _ event: HookEvent,
        status: SessionStatus,
        waitKind: WaitKind?,
        summary: String? = nil
    ) {
        if var s = sessions[event.sessionID] {
            if s.status != status { s.statusSince = event.timestamp }
            s.status = status
            s.waitKind = waitKind
            if let summary { s.summary = summary }
            if let cwd = event.cwd { s.project = Self.projectName(cwd) }
            s.updatedAt = event.timestamp
            sessions[event.sessionID] = s
        } else {
            sessions[event.sessionID] = AgentSession(
                id: event.sessionID,
                agent: event.agent,
                project: event.cwd.map(Self.projectName) ?? "—",
                status: status,
                waitKind: waitKind,
                summary: summary,
                statusSince: event.timestamp,
                updatedAt: event.timestamp
            )
        }
    }

    private mutating func transition(_ event: HookEvent, to status: SessionStatus) {
        guard var s = sessions[event.sessionID] else { return }
        if s.status != status { s.statusSince = event.timestamp }
        s.status = status
        s.waitKind = nil
        s.updatedAt = event.timestamp
        sessions[event.sessionID] = s
    }

    static func projectName(_ cwd: String) -> String {
        let name = URL(fileURLWithPath: cwd).lastPathComponent
        return name.isEmpty ? cwd : name
    }

    static func waitKind(from message: String?) -> WaitKind {
        guard let m = message?.lowercased() else { return .question }
        return m.contains("permission") ? .permission : .question
    }
}
