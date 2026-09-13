import Foundation
import VibeBuddyKit

/// App and extension restore the same atomic privacy-minimized envelope.
enum WatchComplicationStore {
    static let kind = "FollowedTask"
    static let quotaKind = "ProviderQuota"
    static let group = "group.com.vibebuddy.app.watch"
    static var url: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)?
            .appendingPathComponent("followed-task.json")
    }
    static func loadState() -> WatchStoredState? {
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        return WatchStoredState.decode(data)
    }
    static func load() -> WatchComplicationSnapshot? { loadState()?.complication }
    @discardableResult
    static func save(_ state: WatchDashboardState, queue: WatchCompletionQueue,
                     recapQueue: WatchRecapQueue = WatchRecapQueue()) -> Bool {
        guard let url else { return false }
        let next = WatchStoredState(state: state, queue: queue, recapQueue: recapQueue, previous: load())
        do {
            try JSONEncoder().encode(next).write(to: url, options: .atomic)
            return true
        } catch { return false }
    }
}
