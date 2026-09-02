import Foundation
import VibeBuddyKit

/// Pure reducer: folds a stream of `HookEvent`s into the current set of
/// `AgentSession`s. No I/O and no `Date()` — time comes from the events — so it
/// is fully deterministic and unit-testable. Transcript/git enrichment (model,
/// tokens, branch) is layered on by the server, not here.
public struct SessionReducer: Sendable {
    public private(set) var sessions: [String: AgentSession] = [:]
    /// The last per-turn token reading we added to a session's cumulative spend,
    /// so the same turn (re-read on every mid-turn event) is counted only once.
    private var lastCountedTokens: [String: Int] = [:]

    public init() {}

    public mutating func apply(
        _ event: HookEvent,
        observationSource: ObservationSource? = nil
    ) {
        switch event.kind {
        case .sessionStart:
            // Starting or resuming opens a session but does not mean a turn is
            // running yet. Mature monitors call this free/idle; in our three
            // buckets that is `done` until UserPromptSubmit arrives.
            upsert(event, status: .done, waitKind: nil)
            sessions[event.sessionID]?.failed = false
            sessions[event.sessionID]?.activeTool = nil
        case .userPromptSubmit, .preToolUse, .postToolUse:
            // Active work: a tool starting/finishing means the agent is busy,
            // which also clears any prior "needs you" wait state.
            upsert(event, status: .working, waitKind: nil)
            // Track the last tool outcome for the stuck cue and the current tool
            // for the activity line: a new turn clears both, PreToolUse names the
            // running tool, PostToolUse records its outcome and clears the tool.
            switch event.kind {
            case .userPromptSubmit:
                sessions[event.sessionID]?.failed = false
                sessions[event.sessionID]?.activeTool = nil
            case .preToolUse:
                sessions[event.sessionID]?.activeTool = event.toolName
            case .postToolUse:
                sessions[event.sessionID]?.failed = event.toolError
                sessions[event.sessionID]?.activeTool = nil
            default: break
            }
        case .notification:
            // The purpose-built "Claude wants your attention" signal.
            upsert(event, status: .needsResponse,
                   waitKind: Self.waitKind(from: event.message),
                   summary: event.message)
            sessions[event.sessionID]?.failed = false       // waiting on you, not stuck
            sessions[event.sessionID]?.activeTool = nil      // no tool running while waiting
        case .stop:
            // Create-if-missing so a late-observed lifecycle still shows as done;
            // carry the agent's final summary when present.
            upsert(event, status: .done, waitKind: nil, summary: event.message)
            sessions[event.sessionID]?.activeTool = nil
            // Carry the last tool's outcome; also treat a failure-looking stop
            // message as stuck even when no tool error was reported.
            if FailureHeuristic.looksFailed(event.message) { sessions[event.sessionID]?.failed = true }
        case .sessionEnd:
            // The session is over (exit / clear / logout). Drop it entirely so
            // an idle "needs you" prompt doesn't outlive the session it belonged to.
            sessions.removeValue(forKey: event.sessionID)
            lastCountedTokens[event.sessionID] = nil
        case .sessionMetadataChanged:
            // Model and cwd changes describe the same live session. They must
            // not clear its tool/wait state or manufacture a progress transition.
            updateMetadata(event)
        }
        if event.kind != .sessionEnd {
            recordObservation(
                sessionID: event.sessionID,
                source: observationSource ?? event.observationSource ?? .hook,
                at: event.timestamp,
                health: .healthy)
        }
    }

    /// Update one stable source entry without touching session progress.
    public mutating func recordObservation(
        sessionID: String,
        source: ObservationSource,
        at date: Date,
        health: ObservationHealth
    ) {
        guard var session = sessions[sessionID] else { return }
        var observations = session.observations ?? []
        if let index = observations.firstIndex(where: { $0.source == source }) {
            if date >= observations[index].lastObservedAt {
                observations[index].lastObservedAt = date
                observations[index].health = health
            }
        } else {
            observations.append(ObservationEvidence(
                source: source, lastObservedAt: date, health: health))
        }
        session.observations = observations.sorted { $0.source < $1.source }
        sessions[sessionID] = session
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
        if let tokens = info.tokens {
            s.tokens = tokens
            // Accumulate cumulative spend, counting each fresh turn reading once.
            if lastCountedTokens[sessionID] != tokens {
                s.spentTokens = (s.spentTokens ?? 0) + tokens
                lastCountedTokens[sessionID] = tokens
            }
        }
        if let contextTokens = info.contextTokens {
            s.contextTokens = contextTokens
            s.contextWindow = Self.contextWindow(for: info.model ?? s.model)
        }
        if s.status == .needsResponse, let pendingQuestion = info.pendingQuestion {
            s.pendingQuestion = pendingQuestion
            s.pendingApproval = nil
            s.waitKind = .question
            s.summary = pendingQuestion.prompt
        }
        if let summary = info.summary, s.status != .needsResponse { s.summary = summary }
        sessions[sessionID] = s
    }

    /// Context-window size by model. Current Claude (Opus/Sonnet/Haiku 4.x) and
    /// Codex models are 200k; default to that until a model needs a different value.
    static func contextWindow(for model: String?) -> Int { 200_000 }

    /// Mark a known session as blocked on a remote approval.
    public mutating func setPendingApproval(sessionID: String, _ approval: PendingApproval, at: Date) {
        guard var s = sessions[sessionID] else { return }
        if s.status != .needsResponse { s.statusSince = at }
        s.status = .needsResponse
        s.waitKind = .permission
        s.pendingApproval = approval
        s.pendingQuestion = nil
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

    /// Clear an answered question and return the session to working.
    public mutating func clearPendingQuestion(sessionID: String, at: Date) {
        guard var s = sessions[sessionID], s.pendingQuestion != nil else { return }
        s.pendingQuestion = nil
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
    public func snapshot(
        now: Date,
        observationStaleAfter: TimeInterval = 10 * 60,
        observationDiagnostics: [AgentObservationDiagnostic]? = nil
    ) -> Snapshot {
        let aged = sessions.values.map { session -> AgentSession in
            var session = session
            session.observations = session.observations?.map { evidence in
                var evidence = evidence
                if evidence.health == .healthy,
                   now.timeIntervalSince(evidence.lastObservedAt) > observationStaleAfter {
                    evidence.health = .temporarilySilent
                }
                return evidence
            }
            return session
        }
        let sorted = aged.sorted { a, b in
            if a.status.attentionRank != b.status.attentionRank {
                return a.status.attentionRank < b.status.attentionRank
            }
            return a.updatedAt > b.updatedAt
        }
        return Snapshot(sessions: sorted, serverTime: now,
                        observationDiagnostics: observationDiagnostics)
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
            if status != .needsResponse {
                s.pendingQuestion = nil
            }
            if let cwd = event.cwd { s.project = Self.projectName(cwd) }
            if let model = event.model { s.model = model }
            s.updatedAt = event.timestamp
            sessions[event.sessionID] = s
        } else {
            sessions[event.sessionID] = AgentSession(
                id: event.sessionID,
                agent: event.agent,
                project: event.cwd.map(Self.projectName) ?? "—",
                model: event.model,
                status: status,
                waitKind: waitKind,
                summary: summary,
                statusSince: event.timestamp,
                updatedAt: event.timestamp
            )
        }
    }

    private mutating func updateMetadata(_ event: HookEvent) {
        guard var session = sessions[event.sessionID] else {
            sessions[event.sessionID] = AgentSession(
                id: event.sessionID,
                agent: event.agent,
                project: event.cwd.map(Self.projectName) ?? "—",
                model: event.model,
                status: .done,
                statusSince: event.timestamp,
                updatedAt: event.timestamp
            )
            return
        }
        if let cwd = event.cwd { session.project = Self.projectName(cwd) }
        if let model = event.model { session.model = model }
        session.updatedAt = event.timestamp
        sessions[event.sessionID] = session
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
