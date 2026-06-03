import Foundation
import VibeBuddyKit

/// Thread-safe owner of the reducer. The hook intake (writes) and snapshot
/// reads/subscriptions happen concurrently, so the mutable reducer lives behind
/// an actor. WebSocket clients subscribe for a live snapshot stream.
public actor SessionStore {
    private var reducer = SessionReducer()
    private var subscribers: [UUID: AsyncStream<Snapshot>.Continuation] = [:]
    private var needsResponseHandler: (@Sendable (AgentSession) async -> Void)?

    public init() {}

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
        reducer.apply(event)
        if let path = event.transcriptPath, let info = TranscriptReader.read(path: path) {
            reducer.enrich(sessionID: event.sessionID, with: info)
        }
        broadcast()
        if !wasWaiting, let session = reducer.sessions[event.sessionID],
           session.status == .needsResponse, let handler = needsResponseHandler {
            Task { await handler(session) }
        }
        return true
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
