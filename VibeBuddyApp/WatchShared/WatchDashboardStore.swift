import Foundation
import VibeBuddyKit

/// App Group mailbox between the Watch app and its WidgetKit extension.
///
/// The iPhone still owns the relay. The Watch app is the only process that
/// writes here; the complication reads the last accepted `WatchDashboardState`
/// and never talks to the phone itself.
enum WatchDashboardStore {
    static let appGroup = "group.com.vibebuddy.app"
    static let kind = "VibeBuddyWatchCounts"
    private static let key = "watch-dashboard-state"

    static func load() -> WatchDashboardState? {
        guard let data = UserDefaults(suiteName: appGroup)?.data(forKey: key) else { return nil }
        var inbox = WatchStateInbox()
        inbox.accept(data)
        return inbox.state
    }

    static func save(_ state: WatchDashboardState) {
        guard let data = WatchStateInbox.encode(state) else { return }
        UserDefaults(suiteName: appGroup)?.set(data, forKey: key)
    }
}
