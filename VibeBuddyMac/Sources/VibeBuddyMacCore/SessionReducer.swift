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
    /// The turn a session is currently on, for CLIs that label turns
    /// (`HookEvent.turnID`). Grok dispatches a cancelled turn's report off the
    /// command loop, so it can land after the next turn already started.
    private var currentTurnID: [String: String] = [:]

    public init() {}

    /// Seed recent active state recovered from the privacy-minimized journal.
    /// Recovery never re-applies events, so it cannot replay completion alerts.
    /// Child topology is live-only: the journal restores the parent session,
    /// then `childAgents` stay empty until a new start event arrives.
    mutating func restore(_ recovered: [AgentSession]) {
        for var session in recovered {
            session.childAgents = nil
            session.childTopologyDegraded = nil
            sessions[session.id] = session
        }
    }

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
        case .userPromptSubmit:
            if let turnID = event.turnID { currentTurnID[event.sessionID] = turnID }
            upsert(event, status: .working, waitKind: nil)
            sessions[event.sessionID]?.hasUnreadCompletion = false
            sessions[event.sessionID]?.failed = false
            sessions[event.sessionID]?.activeTool = nil
        case .preToolUse, .postToolUse:
            if event.childID != nil {
                // Nested subagent tools describe the child, not parent progress.
                applyNestedChildTool(event)
            } else {
                upsert(event, status: .working, waitKind: nil)
                sessions[event.sessionID]?.hasUnreadCompletion = false
                if event.kind == .preToolUse {
                    sessions[event.sessionID]?.activeTool = event.toolName
                } else {
                    sessions[event.sessionID]?.failed = event.toolError
                    sessions[event.sessionID]?.activeTool = nil
                }
            }
        case .notification:
            // The purpose-built "Claude wants your attention" signal.
            upsert(event, status: .needsResponse,
                   waitKind: Self.waitKind(from: event.message),
                   summary: event.message)
            sessions[event.sessionID]?.failed = false       // waiting on you, not stuck
            sessions[event.sessionID]?.hasUnreadCompletion = false
            sessions[event.sessionID]?.activeTool = nil      // no tool running while waiting
        case .stop:
            // A settle report for a turn the session has already moved past is
            // stale news, not idleness: ignore it rather than showing a false
            // done while the newer turn is still running. A stop with no turn
            // identity (every CLI but grok, plus grok's idle backstop) settles
            // unconditionally.
            if let turnID = event.turnID,
               let current = currentTurnID[event.sessionID], current != turnID {
                break
            }
            // Create-if-missing so a late-observed lifecycle still shows as done;
            // carry the agent's final summary when present.
            upsert(event, status: .done, waitKind: nil, summary: event.message)
            sessions[event.sessionID]?.activeTool = nil
            // Carry the last tool's outcome; also treat a failure-looking stop
            // message as stuck even when no tool error was reported.
            if FailureHeuristic.looksFailed(event.message) { sessions[event.sessionID]?.failed = true }
            // A clean result remains green until an explicit read acknowledgement.
            // Failed endings stay red and do not manufacture a completion unread.
            let cleanCompletion = sessions[event.sessionID]?.isStuck == false
            sessions[event.sessionID]?.hasUnreadCompletion = cleanCompletion
        case .sessionEnd:
            // The session is over (exit / clear / logout). Drop it entirely so
            // an idle "needs you" prompt doesn't outlive the session it belonged to.
            sessions.removeValue(forKey: event.sessionID)
            lastCountedTokens[event.sessionID] = nil
            currentTurnID[event.sessionID] = nil
        case .sessionMetadataChanged:
            // Model and cwd changes describe the same live session. They must
            // not clear its tool/wait state or manufacture a progress transition.
            updateMetadata(event)
        case .childLifecycle:
            applyChildLifecycle(event)
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
        for id in stale {
            sessions.removeValue(forKey: id)
            // The per-session side tables outlive nothing: a session id that
            // comes back (grok resumes one) must start its accounting fresh.
            currentTurnID[id] = nil
            lastCountedTokens[id] = nil
        }
    }

    /// Layer transcript-derived metadata onto an existing session. Model and
    /// token usage always apply; the prose summary only applies when the session
    /// is not waiting on the user (so a permission/question prompt isn't clobbered).
    public mutating func enrich(sessionID: String, with info: TranscriptInfo) {
        guard var s = sessions[sessionID] else { return }
        if let model = info.model { s.model = model }
        if let branch = info.branch { s.branch = branch }
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
            // A source that records the real window (Grok's `signals.json`)
            // wins over the model table, which only knows published defaults.
            s.contextWindow = info.contextWindow
                ?? Self.contextWindow(for: info.model ?? s.model)
        }
        // Only ever *names* a tool the hooks have not named. `PostToolUse` clears
        // `activeTool` before the log records the matching `tool_call_update`,
        // and a `stop` gate fires before `turn_completed` is written, so a
        // transcript read may only fill a gap on a session that is still working.
        if let activeTool = info.activeTool, s.activeTool == nil, s.status == .working {
            s.activeTool = activeTool
        }
        if s.status == .needsResponse, let pendingQuestion = info.pendingQuestion {
            s.pendingQuestion = pendingQuestion
            s.pendingApproval = nil
            s.waitKind = .question
            s.summary = pendingQuestion.prompt
        } else if s.status == .needsResponse, s.pendingApproval == nil, s.pendingQuestion == nil,
                  let tool = info.pendingPermissionTool {
            // The agent's own permission prompt is waiting in its terminal. We
            // cannot answer it remotely, but the phone can at least say what for.
            s.waitKind = .permission
            s.summary = "Permission required: \(tool)"
        }
        // Deliberately last, and deliberately overriding the hook's own
        // `lastAssistantMessage`: the transcript holds the newest prose, and for
        // grok the `stop` envelope's copy is truncated at 32 KiB and stale by
        // the time a later turn's chunks land.
        if let summary = info.summary, s.status != .needsResponse { s.summary = summary }
        sessions[sessionID] = s
    }

    /// Context-window size by model, used only when the source records no real
    /// window of its own. Current Claude (Opus/Sonnet/Haiku 4.x) and Codex
    /// models are 200k; Grok's are 500k.
    static func contextWindow(for model: String?) -> Int {
        guard let model = model?.lowercased() else { return 200_000 }
        return model.hasPrefix("grok") ? 500_000 : 200_000
    }

    /// Mark a known session as blocked on a remote approval.
    public mutating func setPendingApproval(sessionID: String, _ approval: PendingApproval, at: Date) {
        guard var s = sessions[sessionID] else { return }
        if s.status != .needsResponse { s.statusSince = at }
        s.status = .needsResponse
        s.waitKind = .permission
        s.pendingApproval = approval
        s.pendingQuestion = nil
        s.hasUnreadCompletion = false
        s.updatedAt = at
        sessions[sessionID] = s
    }

    /// Clear a resolved/expired approval and return the session to working.
    public mutating func clearPendingApproval(sessionID: String, at: Date) {
        guard var s = sessions[sessionID], s.pendingApproval != nil else { return }
        s.pendingApproval = nil
        s.waitKind = nil
        s.status = .working
        s.hasUnreadCompletion = false
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
        s.hasUnreadCompletion = false
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

    /// Mark a clean completion as read without changing lifecycle timestamps or
    /// list order. Returns whether authoritative state changed.
    @discardableResult
    public mutating func acknowledgeCompletion(sessionID: String) -> Bool {
        guard var session = sessions[sessionID], session.hasUnreadCompletion else { return false }
        session.hasUnreadCompletion = false
        sessions[sessionID] = session
        return true
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
            if a.presentationState.attentionRank != b.presentationState.attentionRank {
                return a.presentationState.attentionRank < b.presentationState.attentionRank
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

    /// Child events may create a parent row so topology is visible, but they
    /// never move the parent's three-state progress.
    private mutating func ensureParentWithoutProgress(_ event: HookEvent, sessionID: String) {
        if sessions[sessionID] == nil {
            sessions[sessionID] = AgentSession(
                id: sessionID,
                agent: event.agent,
                project: event.cwd.map(Self.projectName) ?? "—",
                model: event.model,
                status: .done,
                statusSince: event.timestamp,
                updatedAt: event.timestamp
            )
            return
        }
        // A re-targeted child report describes the child's own working copy, so
        // it must not relabel the parent's project or model.
        if sessionID == event.sessionID {
            if let cwd = event.cwd { sessions[sessionID]?.project = Self.projectName(cwd) }
            if let model = event.model { sessions[sessionID]?.model = model }
        }
        sessions[sessionID]?.updatedAt = event.timestamp
    }

    /// Which session a child report belongs to. Claude reports a child from its
    /// parent, but grok fires `subagent_stop` inside the child's *own* session
    /// (same `subagentId`), which we never track as a session. Re-attach it to
    /// the parent that already owns that child so the row completes instead of
    /// spawning a phantom session.
    private func childLifecycleTarget(_ event: HookEvent) -> String {
        if sessions[event.sessionID] != nil { return event.sessionID }
        guard let childID = event.childID,
              let owner = sessions.values.first(where: {
                  $0.childAgents?.contains { $0.id == childID } == true
              })
        else { return event.sessionID }
        return owner.id
    }

    private mutating func applyNestedChildTool(_ event: HookEvent) {
        ensureParentWithoutProgress(event, sessionID: event.sessionID)
        guard let childID = event.childID else { return }
        updateChild(sessionID: event.sessionID, id: childID, at: event.timestamp) { child in
            if let tool = event.toolName { child.lastActivity = tool }
        }
    }

    private mutating func applyChildLifecycle(_ event: HookEvent) {
        let sessionID = childLifecycleTarget(event)
        // A child's *end* reported from a session we have never seen, for a child
        // no session claims, has no topology to add — inventing a row for it would
        // publish grok's child session as if it were a session of its own. A start
        // still creates the parent so live topology stays visible.
        if sessions[sessionID] == nil, event.childAction != .started { return }
        ensureParentWithoutProgress(event, sessionID: sessionID)
        guard let action = event.childAction, let kind = event.childKind else {
            sessions[sessionID]?.childTopologyDegraded = true
            return
        }
        guard let childID = event.childID else {
            sessions[sessionID]?.childTopologyDegraded = true
            if action == .unknown {
                markRunningChildrenUnknown(sessionID: sessionID, at: event.timestamp)
            }
            return
        }

        var children = sessions[sessionID]?.childAgents ?? []
        let lastActivity = event.message ?? event.toolName
        if let index = children.firstIndex(where: { $0.id == childID }) {
            if event.timestamp < children[index].updatedAt { return }
            children[index].status = status(for: action)
            if let name = event.childName { children[index].name = name }
            if let type = event.childType { children[index].type = type }
            if let lastActivity { children[index].lastActivity = lastActivity }
            children[index].updatedAt = event.timestamp
        } else {
            children.append(ChildAgent(
                id: childID,
                kind: kind,
                name: event.childName,
                type: event.childType,
                status: status(for: action),
                lastActivity: lastActivity,
                updatedAt: event.timestamp
            ))
        }
        sessions[sessionID]?.childAgents = children
    }

    private mutating func updateChild(
        sessionID: String,
        id: String,
        at timestamp: Date,
        mutate: (inout ChildAgent) -> Void
    ) {
        guard var children = sessions[sessionID]?.childAgents,
              let index = children.firstIndex(where: { $0.id == id }) else { return }
        if timestamp < children[index].updatedAt { return }
        mutate(&children[index])
        children[index].updatedAt = timestamp
        sessions[sessionID]?.childAgents = children
    }

    private mutating func markRunningChildrenUnknown(sessionID: String, at timestamp: Date) {
        guard var children = sessions[sessionID]?.childAgents else { return }
        var changed = false
        for index in children.indices where children[index].status == .running {
            if timestamp < children[index].updatedAt { continue }
            children[index].status = .unknown
            children[index].updatedAt = timestamp
            changed = true
        }
        if changed { sessions[sessionID]?.childAgents = children }
    }

    private func status(for action: HookEvent.ChildLifecycleAction) -> ChildAgentStatus {
        switch action {
        case .started: return .running
        case .stopped: return .completed
        case .idled: return .idle
        case .unknown: return .unknown
        }
    }
}
