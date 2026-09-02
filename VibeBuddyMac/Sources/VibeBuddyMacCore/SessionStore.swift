import Foundation
import VibeBuddyKit

/// Thread-safe owner of the reducer. The hook intake (writes) and snapshot
/// reads/subscriptions happen concurrently, so the mutable reducer lives behind
/// an actor. WebSocket clients subscribe for a live snapshot stream.
public actor SessionStore {
    private static let diagnosticStaleAfter: TimeInterval = 10 * 60
    private var reducer = SessionReducer()
    private var subscribers: [UUID: AsyncStream<Snapshot>.Continuation] = [:]
    private var needsResponseHandler: (@Sendable (AgentSession) async -> Void)?
    private var staleAfter: TimeInterval
    /// Per-session transcript path, remembered so `sweep` can check whether a
    /// waiting session's transcript advanced (i.e. the prompt was answered).
    private var transcriptPaths: [String: String] = [:]
    /// Terminal refs remembered by session id, so a `/terminal` POST that races
    /// ahead of the session-creating `SessionStart` still lands once it exists.
    private var pendingTerminalRefs: [String: TerminalRef] = [:]
    private let diagnosticsHome: URL?
    private var runtimeSignals: [AgentKind: [ObservationSource: ObservationRuntimeSignal]] = [:]
    private var diagnosticCache: (at: Date, value: [AgentObservationDiagnostic])?
    private var lifecycleJournal: LifecycleJournal?

    public init(
        staleAfter: TimeInterval = 2 * 60 * 60,
        diagnosticsHome: URL? = nil,
        journalURL: URL? = nil,
        now: Date = Date()
    ) {
        self.staleAfter = staleAfter
        self.diagnosticsHome = diagnosticsHome
        if let journalURL {
            let journal = LifecycleJournal(url: journalURL, now: now)
            self.lifecycleJournal = journal
            reducer.restore(journal.restorableSessions(now: now, meaningfulFor: staleAfter))
        }
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
        for id in removed { transcriptPaths[id] = nil }
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

    /// Parse a raw hook payload, apply it, enrich from the transcript, and push
    /// the new snapshot to every subscriber. Returns false if it wasn't a hook.
    @discardableResult
    public func ingest(_ data: Data, agent: AgentKind = .claudeCode, receivedAt: Date) -> Bool {
        // Source-aware decode: the `?agent=` value tags Claude-shaped lifecycle
        // hooks directly and selects a translator only for different envelopes.
        guard let event = HookDecoder.decode(data, agent: agent, receivedAt: receivedAt)
        else {
            recordSignal(agent: agent, source: .hook, at: receivedAt,
                         health: .unknownVersion, coverage: nil)
            broadcast()
            return false
        }
        ingest(event, observationSource: .hook)
        return true
    }

    /// Apply an already-normalized event from a local monitor such as the Codex
    /// Desktop rollout tailer. Hook payload parsing remains in the Data overload.
    public func ingest(_ event: HookEvent) {
        let inferredSource = event.observationSource ?? (event.agent == .codex ? .rollout : .hook)
        ingest(event, observationSource: inferredSource)
    }

    private func ingest(_ event: HookEvent, observationSource: ObservationSource) {
        let wasWaiting = reducer.sessions[event.sessionID]?.status == .needsResponse
        if let path = event.transcriptPath { transcriptPaths[event.sessionID] = path }
        reducer.apply(event, observationSource: observationSource)
        recordSignal(agent: event.agent, source: observationSource, at: event.timestamp,
                     health: .healthy, coverage: Self.coverage(for: event.kind))
        if reducer.sessions[event.sessionID] == nil {
            // Session was removed (e.g. SessionEnd) — forget its side data.
            transcriptPaths[event.sessionID] = nil
            pendingTerminalRefs[event.sessionID] = nil
        } else {
            if let path = event.transcriptPath {
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
        if !wasWaiting, let session = reducer.sessions[event.sessionID],
           session.status == .needsResponse, let handler = needsResponseHandler {
            Task { await handler(session) }
        }
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
        pendingTerminalRefs[sessionID] = ref          // remembered even if the session isn't here yet
        if reducer.sessions[sessionID] != nil {
            reducer.setTerminalRef(sessionID: sessionID, ref)
            broadcast()
        }
    }

    public func terminalRef(for sessionID: String) -> TerminalRef? {
        reducer.sessions[sessionID]?.terminalRef
    }

    public func snapshot(now: Date) -> Snapshot {
        reducer.snapshot(now: now, observationDiagnostics: diagnostics(now: now))
    }

    /// The session's recent output (user prompts + assistant prose / tool activity)
    /// for the detail pane. Empty when the session has no known transcript, so
    /// the UI can show a graceful "no transcript" state.
    public func recentTranscript(sessionID: String, limit: Int = 12) -> [TranscriptEntry] {
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
        let now = Date()
        subscribers[id]?.yield(reducer.snapshot(
            now: now, observationDiagnostics: diagnostics(now: now)))
        return (id, stream)
    }

    public func unsubscribe(_ id: UUID) {
        subscribers[id]?.finish()
        subscribers[id] = nil
    }

    private func broadcast() {
        let now = Date()
        let snapshot = reducer.snapshot(now: now, observationDiagnostics: diagnostics(now: now))
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
            staleAfter: Self.diagnosticStaleAfter)
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
