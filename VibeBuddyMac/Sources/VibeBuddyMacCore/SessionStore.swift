import Foundation
import VibeBuddyKit

/// Thread-safe owner of the reducer. The hook intake (writes) and snapshot
/// reads happen concurrently, so the mutable reducer lives behind an actor.
public actor SessionStore {
    private var reducer = SessionReducer()

    public init() {}

    /// Parse a raw hook payload and apply it. Returns false if it wasn't a
    /// recognizable hook (ignored).
    @discardableResult
    public func ingest(_ data: Data, receivedAt: Date) -> Bool {
        guard let event = HookParser.parse(data, receivedAt: receivedAt) else { return false }
        reducer.apply(event)
        return true
    }

    public func snapshot(now: Date) -> Snapshot {
        reducer.snapshot(now: now)
    }
}
