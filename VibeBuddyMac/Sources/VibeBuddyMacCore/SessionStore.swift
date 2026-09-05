import Foundation
import VibeBuddyKit

/// Thread-safe owner of the reducer. The hook intake (writes) and snapshot
/// reads/subscriptions happen concurrently, so the mutable reducer lives behind
/// an actor. WebSocket clients subscribe for a live snapshot stream.
public actor SessionStore {
    private static let diagnosticStaleAfter: TimeInterval = 10 * 60
    private var reducer = SessionReducer()
    /// Account allowance, kept beside the reducer rather than inside it.
    private var providerQuota: [ProviderQuota] = []
    private var subscribers: [UUID: AsyncStream<Snapshot>.Continuation] = [:]
    private var needsResponseHandler: (@Sendable (AgentSession) async -> Void)?
    private var staleAfter: TimeInterval
    /// Per-session transcript path, remembered so `sweep` can check whether a
    /// waiting session's transcript advanced (i.e. the prompt was answered).
    private var transcriptPaths: [String: String] = [:]
    /// Terminal refs remembered by session id, so a `/terminal` POST that races
    /// ahead of the session-creating `SessionStart` still lands once it exists.
    private var pendingTerminalRefs: [String: TerminalRef] = [:]
    /// Resolved `~/.grok/sessions/<cwd>/<id>` directories. Grok's hook envelope
    /// names no transcript on every event, and the fallback is a directory
    /// scan, so the answer is remembered for the life of the session.
    private var grokDirectories: [String: URL] = [:]
    /// Grok's own data directory (`$GROK_HOME`, else `~/.grok`), not the user's
    /// home: the session store is rooted at `<grok home>/sessions`.
    private let grokHome: URL
    private let diagnosticsHome: URL?
    private var runtimeSignals: [AgentKind: [ObservationSource: ObservationRuntimeSignal]] = [:]
    private var diagnosticCache: (at: Date, value: [AgentObservationDiagnostic])?
    private var lifecycleJournal: LifecycleJournal?
    /// The user's hand-set attention levels, layered onto every snapshot.
    private var attention: AttentionOverrides
    /// When the user last drove each session (prompt, jump, decision, answer);
    /// what `AutoAttention` reads when there is no hand-set level.
    private var lastInteractionAt: [String: Date] = [:]

    public init(
        staleAfter: TimeInterval = 2 * 60 * 60,
        diagnosticsHome: URL? = nil,
        journalURL: URL? = nil,
        attentionURL: URL? = nil,
        grokHome: URL? = nil,
        now: Date = Date()
    ) {
        self.staleAfter = staleAfter
        self.diagnosticsHome = diagnosticsHome
        self.grokHome = grokHome ?? GrokHome.url
        if let journalURL {
            let journal = LifecycleJournal(url: journalURL, now: now)
            self.lifecycleJournal = journal
            reducer.restore(journal.restorableSessions(now: now, meaningfulFor: staleAfter))
        }
        var attention = AttentionOverrides(url: attentionURL)
        attention.prune(keeping: Set(reducer.sessions.keys))
        self.attention = attention
    }

    /// Set (or with `nil` clear) the user's attention choice for a live session.
    /// Returns false when no such session exists — there is nothing to attach
    /// the choice to, and it would never be pruned.
    @discardableResult
    public func setAttention(sessionID: String, _ level: SessionAttention?) -> Bool {
        guard reducer.sessions[sessionID] != nil else { return false }
        attention.set(level, for: sessionID)
        broadcast()
        return true
    }

    /// The user just acted on this session — typed a prompt, jumped to it,
    /// decided its approval, answered its question. Keeps it `followed` for
    /// `AutoAttention.window` unless a hand-set level says otherwise.
    public func recordInteraction(sessionID: String, at: Date = Date()) {
        guard reducer.sessions[sessionID] != nil else { return }
        lastInteractionAt[sessionID] = at
        broadcast()
    }

    /// Change the idle-cleanup window at runtime (from Settings).
    public func setStaleAfter(_ interval: TimeInterval) { staleAfter = interval }

    /// Self-heal: drop `needsResponse` sessions that are answered (transcript
    /// advanced past `statusSince`) or abandoned (idle past `staleAfter`), even
    /// when their terminal hook was never received. Broadcasts if anything changed.
    public func sweep(now: Date) {
        var lastActivity: [String: Date] = [:]
        for (id, session) in reducer.sessions where session.status == .needsResponse {
            if let path = transcriptPaths[id], let mtime = Self.modificationDate(path) {
                lastActivity[id] = mtime
            }
        }
        let before = reducer.sessions
        reducer.reconcile(now: now, lastActivity: lastActivity, staleAfter: staleAfter)
        let removed = Set(before.keys).subtracting(reducer.sessions.keys)
        for id in removed {
            transcriptPaths[id] = nil
            grokDirectories[id] = nil
            lastInteractionAt[id] = nil
        }
        attention.prune(keeping: Set(reducer.sessions.keys))
        for id in removed {
            guard let session = before[id] else { continue }
            appendJournal(
                sessionID: id, agent: session.agent, event: "sessionReconciled",
                source: .recovery, at: now
            )
        }
        if !removed.isEmpty { broadcast() }
    }

    private static func modificationDate(_ path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }

    /// Called once per fresh transition into needsResponse (used for APNs push).
    public func setNeedsResponseHandler(_ handler: @escaping @Sendable (AgentSession) async -> Void) {
        needsResponseHandler = handler
    }

    /// True when a session with this id is currently tracked.
    public func hasSession(_ id: String) -> Bool {
        reducer.sessions[id] != nil
    }

    /// Parse a raw hook payload, apply it, enrich from the transcript, and push
    /// the new snapshot to every subscriber. Returns false if it wasn't a hook.
    /// `announcesWait: false` applies the event without firing the
    /// needs-response handler — for a wait the caller is about to announce
    /// itself (a `PermissionRequest` gate that opens an unknown session right
    /// before `beginApproval`), so one request never produces two pushes.
    @discardableResult
    public func ingest(_ data: Data, agent: AgentKind = .claudeCode, receivedAt: Date,
                       announcesWait: Bool = true) -> Bool {
        // Source-aware decode: the `?agent=` value tags Claude-shaped lifecycle
        // hooks directly and selects a translator only for different envelopes.
        switch HookDecoder.decode(data, agent: agent, receivedAt: receivedAt) {
        case let .event(event):
            ingest(event, observationSource: .hook, announcesWait: announcesWait)
            return true
        case .ignored:
            // Understood, but carries no progress (grok fires several such events
            // per session). The hook source is demonstrably alive and speaking a
            // shape we know, so record it as healthy rather than as an unknown
            // version — but claim no event-family coverage for it.
            recordSignal(agent: agent, source: .hook, at: receivedAt,
                         health: .healthy, coverage: nil)
            broadcast()
            return false
        case .undecodable:
            recordSignal(agent: agent, source: .hook, at: receivedAt,
                         health: .unknownVersion, coverage: nil)
            broadcast()
            return false
        }
    }

    /// Apply an already-normalized event from a local monitor such as the Codex
    /// Desktop rollout tailer. Hook payload parsing remains in the Data overload.
    /// Probe retirement passes `recordsEvidence: false` so a synthetic stop
    /// still migrates progress without minting rollout health evidence.
    public func ingest(_ event: HookEvent, recordsEvidence: Bool = true) {
        let inferredSource = event.observationSource ?? (event.agent == .codex ? .rollout : .hook)
        ingest(event, observationSource: inferredSource, recordsEvidence: recordsEvidence)
    }

    private func ingest(
        _ event: HookEvent,
        observationSource: ObservationSource,
        recordsEvidence: Bool = true,
        announcesWait: Bool = true
    ) {
        let wasWaiting = reducer.sessions[event.sessionID]?.status == .needsResponse
        if let path = event.transcriptPath { transcriptPaths[event.sessionID] = path }
        reducer.apply(event, observationSource: observationSource, recordsEvidence: recordsEvidence)
        // A prompt is the user driving the session in person.
        if event.kind == .userPromptSubmit { lastInteractionAt[event.sessionID] = event.timestamp }
        if let enrichment = event.enrichment {
            reducer.enrich(sessionID: event.sessionID, with: enrichment)
        }
        if recordsEvidence {
            recordSignal(agent: event.agent, source: observationSource, at: event.timestamp,
                         health: .healthy, coverage: Self.coverage(for: event.kind))
        }
        if reducer.sessions[event.sessionID] == nil {
            // Session was removed (e.g. SessionEnd) — forget its side data.
            transcriptPaths[event.sessionID] = nil
            pendingTerminalRefs[event.sessionID] = nil
            grokDirectories[event.sessionID] = nil
            lastInteractionAt[event.sessionID] = nil
            attention.set(nil, for: event.sessionID)
        } else {
            // Grok keeps a session's facts in a directory of files rather than
            // one transcript, so it enriches from that directory instead.
            if event.agent == .grok {
                enrichFromGrokSession(event)
            } else if let path = event.transcriptPath {
                let transcriptHealth = Self.sourceHealth(at: path)
                reducer.recordObservation(sessionID: event.sessionID, source: .transcript,
                                          at: event.timestamp, health: transcriptHealth)
                recordSignal(agent: event.agent, source: .transcript, at: event.timestamp,
                             health: transcriptHealth, coverage: .turn)
                if let info = TranscriptReader.read(path: path) {
                    reducer.enrich(sessionID: event.sessionID, with: info)
                }
            }
            // Apply a terminal ref that arrived before this session existed.
            if let ref = pendingTerminalRefs[event.sessionID] {
                reducer.setTerminalRef(sessionID: event.sessionID, ref)
            }
        }
        appendJournal(
            sessionID: event.sessionID,
            agent: event.agent,
            event: event.kind.rawValue,
            source: observationSource,
            at: event.timestamp
        )
        broadcast()
        if announcesWait, !wasWaiting, let session = reducer.sessions[event.sessionID],
           session.status == .needsResponse, let handler = needsResponseHandler {
            Task { await handler(session) }
        }
    }

    /// Layer a Grok session directory's facts onto the session, and fold the
    /// subagents the parent recorded into the same child topology the hook path
    /// builds. The directory is the only source that names the children a
    /// parent owns: `subagent_stop` fires inside the child's own session.
    private func enrichFromGrokSession(_ event: HookEvent) {
        guard let directory = grokSessionDirectory(for: event) else { return }
        let health = Self.sourceHealth(
            at: directory.appendingPathComponent("updates.jsonl").path)
        reducer.recordObservation(sessionID: event.sessionID, source: .transcript,
                                  at: event.timestamp, health: health)
        recordSignal(agent: .grok, source: .transcript, at: event.timestamp,
                     health: health, coverage: .turn)
        guard let snapshot = GrokSessionReader.read(directory: directory) else { return }
        reducer.enrich(sessionID: event.sessionID, with: snapshot.info)

        // The hook path is authoritative on a child's *state*: `SubagentStop`
        // fires before the child's teardown rewrites `meta.json`, so the
        // directory still says "running" for a child we already know finished.
        // The directory may therefore only introduce children the hooks missed,
        // and stop children — never move one back to running.
        let known = Set(reducer.sessions[event.sessionID]?.childAgents?.map(\.id) ?? [])
        for child in snapshot.subagents {
            let childID = "subagent:\(child.id)"       // same identity GrokParser mints
            guard child.finished || !known.contains(childID) else { continue }
            // Stamped with the observing event, not the child's own start time:
            // the reducer drops child updates older than what it already holds,
            // and a long-finished subagent must not rewind the parent's clock.
            reducer.apply(HookEvent(
                kind: .childLifecycle,
                sessionID: event.sessionID,
                agent: .grok,
                message: child.detail,
                observationSource: .transcript,
                timestamp: event.timestamp,
                childID: childID,
                childKind: .subagent,
                childName: child.type,
                childType: child.type,
                childAction: child.finished ? .stopped : .started
            ), observationSource: .transcript)
        }
    }

    /// The session directory for a Grok event: the parent of the hook's
    /// `transcriptPath` (it names `updates.jsonl`) when there is one, else the
    /// locator over the session's cwd. Cached once resolved.
    private func grokSessionDirectory(for event: HookEvent) -> URL? {
        if let cached = grokDirectories[event.sessionID] { return cached }
        let resolved = event.transcriptPath.flatMap(GrokSessionLocator.directory(forTranscriptPath:))
            ?? GrokSessionLocator.locate(sessionID: event.sessionID, cwd: event.cwd,
                                         grokHome: grokHome)
        guard let resolved else { return nil }
        grokDirectories[event.sessionID] = resolved
        // `sweep` measures "did the session advance" from this path's mtime.
        transcriptPaths[event.sessionID] = resolved
            .appendingPathComponent("updates.jsonl").path
        return resolved
    }

    public func beginApproval(sessionID: String, _ approval: PendingApproval, at: Date) {
        reducer.setPendingApproval(sessionID: sessionID, approval, at: at)
        if let session = reducer.sessions[sessionID] {
            appendJournal(sessionID: sessionID, agent: session.agent,
                          event: "approvalRequested", source: .hook, at: at)
        }
        broadcast()
        if let session = reducer.sessions[sessionID], let handler = needsResponseHandler {
            Task { await handler(session) }
        }
    }

    public func endApproval(sessionID: String, at: Date) {
        reducer.clearPendingApproval(sessionID: sessionID, at: at)
        if let session = reducer.sessions[sessionID] {
            appendJournal(sessionID: sessionID, agent: session.agent,
                          event: "approvalResolved", source: .hook, at: at)
        }
        broadcast()
    }

    public func endQuestion(sessionID: String, at: Date) {
        reducer.clearPendingQuestion(sessionID: sessionID, at: at)
        if let session = reducer.sessions[sessionID] {
            appendJournal(sessionID: sessionID, agent: session.agent,
                          event: "questionResolved", source: .hook, at: at)
        }
        broadcast()
    }

    public func setTerminalRef(sessionID: String, _ ref: TerminalRef) {
        // Remembered even if the session isn't here yet — and merged for the
        // same reason the reducer merges: a re-capture that skipped the Ghostty
        // probe must not erase the id the first one found.
        pendingTerminalRefs[sessionID] = pendingTerminalRefs[sessionID]?.merging(ref) ?? ref
        if reducer.sessions[sessionID] != nil {
            reducer.setTerminalRef(sessionID: sessionID, ref)
            broadcast()
        }
    }

    public func terminalRef(for sessionID: String) -> TerminalRef? {
        reducer.sessions[sessionID]?.terminalRef
    }

    /// The Codex Desktop thread a session is, when it is one. The rollout tailer
    /// is the only writer, through the events it already sends.
    public func desktopThreadID(for sessionID: String) -> String? {
        reducer.sessions[sessionID]?.desktopThreadID
    }

    /// Authoritative read acknowledgement. Snapshot delivery and passive list
    /// visibility never call this; only explicit selection/open/jump actions do.
    @discardableResult
    public func acknowledgeCompletion(sessionID: String) -> Bool {
        let changed = reducer.acknowledgeCompletion(sessionID: sessionID)
        if changed { broadcast() }
        return changed
    }

    public func snapshot(now: Date) -> Snapshot {
        currentSnapshot(now: now)
    }

    /// Replace the current account allowance. It is composed into every snapshot
    /// but never reaches the reducer: quota is account state, not session
    /// progress, and a provider outage must not move a single session.
    /// A change broadcasts, so the phone and the wrist see it without waiting
    /// for the next session event.
    public func setProviderQuota(_ quota: [ProviderQuota]) {
        guard quota != providerQuota else { return }
        providerQuota = quota
        broadcast()
    }

    /// The one place a runtime snapshot is assembled: sessions and diagnostics
    /// from the reducer, allowance from beside it.
    private func currentSnapshot(now: Date) -> Snapshot {
        var snapshot = reducer.snapshot(now: now, observationDiagnostics: diagnostics(now: now))
        snapshot.providerQuota = providerQuota.isEmpty ? nil : providerQuota
        snapshot.sessions = snapshot.sessions.map { session in
            var session = session
            session.attentionOverride = attention[session.id]
            session.attention = attention[session.id]
                ?? AutoAttention.level(lastInteractionAt: lastInteractionAt[session.id], now: now)
            return session
        }
        return snapshot
    }

    /// The session's recent output (user prompts + assistant prose / tool activity)
    /// for the detail pane. Empty when the session has no known transcript, so
    /// the UI can show a graceful "no transcript" state.
    public func recentTranscript(sessionID: String, limit: Int = 12) -> [TranscriptEntry] {
        if let directory = grokDirectories[sessionID] {
            return GrokSessionReader.recentEntries(directory: directory, limit: limit)
        }
        guard let path = transcriptPaths[sessionID] else { return [] }
        return TranscriptReader.recentEntries(path: path, limit: limit) ?? []
    }

    /// Privacy-minimized lifecycle diagnostics, newest first.
    public func recentLifecycle(limit: Int = 40) -> [LifecycleJournalEntry] {
        lifecycleJournal?.recent(limit: limit) ?? []
    }

    /// Explicitly erase the lifecycle journal. Returns false and retains the
    /// in-memory timeline when on-disk data could not be removed, allowing retry.
    @discardableResult
    public func clearLifecycleJournal() -> Bool {
        guard var journal = lifecycleJournal else { return true }
        let removed = journal.clear()
        lifecycleJournal = journal
        return removed
    }

    /// Subscribe to live snapshots. The current snapshot is delivered immediately.
    public func subscribe() -> (id: UUID, stream: AsyncStream<Snapshot>) {
        let id = UUID()
        let stream = AsyncStream<Snapshot>(bufferingPolicy: .bufferingNewest(1)) { continuation in
            subscribers[id] = continuation
        }
        subscribers[id]?.yield(currentSnapshot(now: Date()))
        return (id, stream)
    }

    public func unsubscribe(_ id: UUID) {
        subscribers[id]?.finish()
        subscribers[id] = nil
    }

    private func broadcast() {
        let snapshot = currentSnapshot(now: Date())
        for continuation in subscribers.values {
            continuation.yield(snapshot)
        }
    }

    private func appendJournal(
        sessionID: String,
        agent: AgentKind,
        event: String,
        source: ObservationSource,
        at timestamp: Date
    ) {
        // Session IDs are normally UUID-sized. Refuse an untrusted oversized ID
        // so the record-count limit also remains a practical byte-size bound.
        guard sessionID.utf8.count <= 256 else { return }
        guard var journal = lifecycleJournal else { return }
        let result = reducer.sessions[sessionID]
        journal.append(LifecycleJournalEntry(
            sessionID: sessionID,
            agent: agent,
            event: event,
            source: source,
            timestamp: timestamp,
            status: result?.status,
            waitKind: result?.waitKind
        ), now: timestamp)
        lifecycleJournal = journal
    }

    private func diagnostics(now: Date) -> [AgentObservationDiagnostic]? {
        let signals = runtimeSignals.values.flatMap { $0.values }
        guard diagnosticsHome != nil || !signals.isEmpty else { return nil }
        if let cache = diagnosticCache, now.timeIntervalSince(cache.at) < 30 {
            return cache.value
        }
        let value = ObservationHealthDetector.detect(
            home: diagnosticsHome, signals: signals, now: now,
            staleAfter: Self.diagnosticStaleAfter, grokHome: grokHome)
        diagnosticCache = (now, value)
        return value
    }

    private func recordSignal(
        agent: AgentKind,
        source: ObservationSource,
        at date: Date,
        health: ObservationHealth,
        coverage: ObservationEventCoverage?
    ) {
        var perSource = runtimeSignals[agent] ?? [:]
        let previous = perSource[source]
        var signal = previous ?? ObservationRuntimeSignal(
            agent: agent, source: source, lastObservedAt: date, health: health)
        if date >= signal.lastObservedAt {
            signal.lastObservedAt = date
            signal.health = health
        }
        if let coverage {
            signal.observedCoverage = Array(Set(signal.observedCoverage).union([coverage])).sorted()
        }
        perSource[source] = signal
        runtimeSignals[agent] = perSource
        let patchedCache = patchDiagnosticCache(with: signal)
        // Static compatibility evidence is comparatively expensive to inspect.
        // Rebuild it when a source first appears or its state/coverage changes;
        // ordinary timestamp advances can use the bounded 30-second cache.
        if !patchedCache && (previous == nil
            || previous?.health != signal.health
            || previous?.observedCoverage != signal.observedCoverage) {
            diagnosticCache = nil
        }
    }

    /// Patch freshness-only rows in memory. Static compatibility failures still
    /// invalidate once when the runtime signal materially changes.
    private func patchDiagnosticCache(with signal: ObservationRuntimeSignal) -> Bool {
        guard var cache = diagnosticCache,
              let agentIndex = cache.value.firstIndex(where: { $0.agent == signal.agent }),
              let sourceIndex = cache.value[agentIndex].sources
                .firstIndex(where: { $0.source == signal.source }) else { return false }
        var row = cache.value[agentIndex].sources[sourceIndex]
        guard row.health == .healthy || row.health == .temporarilySilent else { return false }

        row.lastObservedAt = max(row.lastObservedAt ?? signal.lastObservedAt,
                                 signal.lastObservedAt)
        row.observedCoverage = Array(
            Set(row.observedCoverage).union(signal.observedCoverage)).sorted()
        if signal.health != .healthy {
            row.health = signal.health
        } else {
            row.health = cache.at.timeIntervalSince(signal.lastObservedAt)
                > Self.diagnosticStaleAfter ? .temporarilySilent : .healthy
        }
        cache.value[agentIndex].sources[sourceIndex] = row
        diagnosticCache = cache
        return true
    }

    private static func coverage(for kind: HookEvent.Kind) -> ObservationEventCoverage {
        if kind == .userPromptSubmit || kind == .stop { return .turn }
        if kind == .preToolUse || kind == .postToolUse { return .tool }
        if kind == .notification { return .attention }
        return .lifecycle
    }

    private static func sourceHealth(at path: String) -> ObservationHealth {
        let fm = FileManager.default
        guard fm.fileExists(atPath: path),
              fm.isReadableFile(atPath: path),
              let attributes = try? fm.attributesOfItem(atPath: path),
              ((attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0) & 0o444 != 0
        else { return .sourceUnreadable }
        return .healthy
    }
}
