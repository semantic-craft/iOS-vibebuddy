import Foundation
import VibeBuddyKit

/// Thread-safe owner of the reducer. The hook intake (writes) and snapshot
/// reads/subscriptions happen concurrently, so the mutable reducer lives behind
/// an actor. WebSocket clients subscribe for a live snapshot stream.
public actor SessionStore {
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

    public init(staleAfter: TimeInterval = 2 * 60 * 60) {
        self.staleAfter = staleAfter
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
        let before = Set(reducer.sessions.keys)
        reducer.reconcile(now: now, lastActivity: lastActivity, staleAfter: staleAfter)
        let removed = before.subtracting(reducer.sessions.keys)
        for id in removed { transcriptPaths[id] = nil }
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
        else { return false }
        ingest(event)
        return true
    }

    /// Apply an already-normalized event from a local monitor such as the Codex
    /// Desktop rollout tailer. Hook payload parsing remains in the Data overload.
    public func ingest(_ event: HookEvent) {
        let wasWaiting = reducer.sessions[event.sessionID]?.status == .needsResponse
        if let path = event.transcriptPath { transcriptPaths[event.sessionID] = path }
        reducer.apply(event)
        if reducer.sessions[event.sessionID] == nil {
            // Session was removed (e.g. SessionEnd) — forget its side data.
            transcriptPaths[event.sessionID] = nil
            pendingTerminalRefs[event.sessionID] = nil
        } else {
            if let path = event.transcriptPath, let info = TranscriptReader.read(path: path) {
                reducer.enrich(sessionID: event.sessionID, with: info)
            }
            // Apply a terminal ref that arrived before this session existed.
            if let ref = pendingTerminalRefs[event.sessionID] {
                reducer.setTerminalRef(sessionID: event.sessionID, ref)
            }
        }
        broadcast()
        if !wasWaiting, let session = reducer.sessions[event.sessionID],
           session.status == .needsResponse, let handler = needsResponseHandler {
            Task { await handler(session) }
        }
    }

    public func beginApproval(sessionID: String, _ approval: PendingApproval, at: Date) {
        reducer.setPendingApproval(sessionID: sessionID, approval, at: at)
        broadcast()
        if let session = reducer.sessions[sessionID], let handler = needsResponseHandler {
            Task { await handler(session) }
        }
    }

    public func endApproval(sessionID: String, at: Date) {
        reducer.clearPendingApproval(sessionID: sessionID, at: at)
        broadcast()
    }

    public func endQuestion(sessionID: String, at: Date) {
        reducer.clearPendingQuestion(sessionID: sessionID, at: at)
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
        reducer.snapshot(now: now)
    }

    /// The session's recent output (user prompts + assistant prose / tool activity)
    /// for the detail pane. Empty when the session has no known transcript, so
    /// the UI can show a graceful "no transcript" state.
    public func recentTranscript(sessionID: String, limit: Int = 12) -> [TranscriptEntry] {
        guard let path = transcriptPaths[sessionID] else { return [] }
        return TranscriptReader.recentEntries(path: path, limit: limit) ?? []
    }

    /// Subscribe to live snapshots. The current snapshot is delivered immediately.
    public func subscribe() -> (id: UUID, stream: AsyncStream<Snapshot>) {
        let id = UUID()
        let stream = AsyncStream<Snapshot>(bufferingPolicy: .bufferingNewest(1)) { continuation in
            subscribers[id] = continuation
        }
        subscribers[id]?.yield(reducer.snapshot(now: Date()))
        return (id, stream)
    }

    public func unsubscribe(_ id: UUID) {
        subscribers[id]?.finish()
        subscribers[id] = nil
    }

    private func broadcast() {
        let snapshot = reducer.snapshot(now: Date())
        for continuation in subscribers.values {
            continuation.yield(snapshot)
        }
    }
}
