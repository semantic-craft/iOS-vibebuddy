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
            // Create-if-missing so a late-observed session or a Codex
            // turn-complete still shows as done; carry a Codex summary if present.
            upsert(event, status: .done, waitKind: nil, summary: event.message)
        case .sessionEnd:
            // The session is over (exit / clear / logout). Drop it entirely so
            // an idle "needs you" prompt doesn't outlive the session it belonged to.
            sessions.removeValue(forKey: event.sessionID)
        }
    }

    /// Self-healing pass for sessions that are no longer genuinely waiting but
    /// whose clearing event the daemon never saw (force-kill, dropped POST,
    /// daemon restart). Drops a `needsResponse` session when either:
    ///  - its transcript was modified *after* it began waiting (`lastActivity`
    ///    is the transcript's last-modified time) — the prompt was answered, or
    ///  - it has been idle longer than `staleAfter` with no fresh activity.
    /// `working`/`done` sessions are never touched — they self-correct via events.
    public mutating func reconcile(now: Date, lastActivity: [String: Date], staleAfter: TimeInterval) {
        let stale = sessions.values.filter { s in
            guard s.status == .needsResponse else { return false }
            let answered = lastActivity[s.id].map { $0 > s.statusSince } ?? false
            let abandoned = now.timeIntervalSince(s.updatedAt) > staleAfter
            return answered || abandoned
        }.map(\.id)
        for id in stale { sessions.removeValue(forKey: id) }
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

    /// Mark a known session as blocked on a remote approval.
    public mutating func setPendingApproval(sessionID: String, _ approval: PendingApproval, at: Date) {
        guard var s = sessions[sessionID] else { return }
        if s.status != .needsResponse { s.statusSince = at }
        s.status = .needsResponse
        s.waitKind = .permission
        s.pendingApproval = approval
        s.updatedAt = at
        sessions[sessionID] = s
    }

    /// Clear a resolved/expired approval and return the session to working.
    public mutating func clearPendingApproval(sessionID: String, at: Date) {
        guard var s = sessions[sessionID], s.pendingApproval != nil else { return }
        s.pendingApproval = nil
        s.waitKind = nil
        s.status = .working
        s.statusSince = at
        s.updatedAt = at
        sessions[sessionID] = s
    }

    /// Attach the terminal a session runs in (does not change status).
    public mutating func setTerminalRef(sessionID: String, _ ref: TerminalRef) {
        guard var s = sessions[sessionID] else { return }
        s.terminalRef = ref
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
            let wasWaiting = s.status == .needsResponse
            if s.status != status { s.statusSince = event.timestamp }
            s.status = status
            s.waitKind = waitKind
            if let summary {
                s.summary = summary
            } else if wasWaiting, status != .needsResponse {
                // Leaving a wait without a replacement: drop the stale "needs you"
                // prompt so a done/working row never shows a permission/question
                // line. Transcript enrichment refills it when prose is available.
                s.summary = nil
            }
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

    static func projectName(_ cwd: String) -> String {
        let name = URL(fileURLWithPath: cwd).lastPathComponent
        return name.isEmpty ? cwd : name
    }

    static func waitKind(from message: String?) -> WaitKind {
        guard let m = message?.lowercased() else { return .question }
        return m.contains("permission") ? .permission : .question
    }
}
