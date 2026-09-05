import Foundation
import VibeBuddyKit

/// Account usage that arrives on its own, without a scheduled fetch: Claude's
/// status line carries `rate_limits` on every event, and the Codex app-server
/// daemon answers `account/rateLimits/read` at once and streams
/// `account/rateLimits/updated`. Sources publish here; the usage coordinator
/// consumes the stream and holds off the spawning collectors while a live
/// sample is fresh. Like the collectors, this never touches session state.
public actor AccountUsageLiveFeed {
    private var latest: [AccountUsageProvider: AccountUsageSnapshot] = [:]
    private var subscribers: [UUID: AsyncStream<AccountUsageSnapshot>.Continuation] = [:]

    public init() {}

    public func publish(_ snapshot: AccountUsageSnapshot) {
        latest[snapshot.provider] = snapshot
        for continuation in subscribers.values { continuation.yield(snapshot) }
    }

    public func latest(for provider: AccountUsageProvider) -> AccountUsageSnapshot? {
        latest[provider]
    }

    public func subscribe() -> (id: UUID, stream: AsyncStream<AccountUsageSnapshot>) {
        let id = UUID()
        let stream = AsyncStream<AccountUsageSnapshot>(bufferingPolicy: .bufferingNewest(8)) { continuation in
            subscribers[id] = continuation
        }
        return (id, stream)
    }

    public func unsubscribe(_ id: UUID) {
        subscribers.removeValue(forKey: id)?.finish()
    }
}
