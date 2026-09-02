import SwiftUI
import VibeBuddyKit

@main
struct VibeBuddyWatchApp: App {
    @StateObject private var store = WatchStateStore()

    var body: some Scene {
        WindowGroup {
            WatchRootView(store: store)
        }
    }
}

/// The pages of the companion. The *top* alert is not a page: it takes over the
/// home screen, so a blocked session cannot be swiped past by accident. The
/// Alerts page carries the queue behind it, and only exists while there is a
/// queue.
enum WatchPage: String, Hashable {
    case home
    case alerts
    case quota
}
