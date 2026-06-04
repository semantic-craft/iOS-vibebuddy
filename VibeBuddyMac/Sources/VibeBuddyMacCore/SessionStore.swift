import Foundation
import VibeBuddyKit

/// Thread-safe owner of the reducer. The hook intake (writes) and snapshot
/// reads/subscriptions happen concurrently, so the mutable reducer lives behind
/// an actor. WebSocket clients subscribe for a live snapshot stream.
public actor SessionStore {
    private var reducer = SessionReducer()
    private var subscribers: [UUID: AsyncStream<Snapshot>.Continuation] = [:]
    private var needsResponseHandler: (@Sendable (AgentSession) async -> Void)?
    private let staleAfter: TimeInterval
    /// Per-session transcript path, remembered so `sweep` can check whether a
    /// waiting session's transcript advanced (i.e. the prompt was answered).
    private var transcriptPaths: [String: String] = [:]

    public init(staleAfter: TimeInterval = 2 * 60 * 60) {
        self.staleAfter = staleAfter
    }

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
        // Claude Code / Codex hooks first (hook_event_name); Codex notify second.
        guard let event = HookParser.parse(data, agent: agent, receivedAt: receivedAt)
            ?? CodexParser.parse(data, receivedAt: receivedAt)
        else { return false }
        let wasWaiting = reducer.sessions[event.sessionID]?.status == .needsResponse
        if let path = event.transcriptPath { transcriptPaths[event.sessionID] = path }
        reducer.apply(event)
        if reducer.sessions[event.sessionID] == nil {
            // Session was removed (e.g. SessionEnd) — forget its transcript path.
            transcriptPaths[event.sessionID] = nil
        } else if let path = event.transcriptPath, let info = TranscriptReader.read(path: path) {
            reducer.enrich(sessionID: event.sessionID, with: info)
        }
        broadcast()
        if !wasWaiting, let session = reducer.sessions[event.sessionID],
           session.status == .needsResponse, let handler = needsResponseHandler {
            Task { await handler(session) }
        }
        return true
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

    public func setTerminalRef(sessionID: String, _ ref: TerminalRef) {
        reducer.setTerminalRef(sessionID: sessionID, ref)
        broadcast()
    }

    public func terminalRef(for sessionID: String) -> TerminalRef? {
        reducer.sessions[sessionID]?.terminalRef
    }

    public func snapshot(now: Date) -> Snapshot {
        reducer.snapshot(now: now)
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
