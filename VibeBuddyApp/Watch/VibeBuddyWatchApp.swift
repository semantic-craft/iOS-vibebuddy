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

/// The two pages of the companion. The urgent alert is not a page: it takes
/// over the home screen, so a blocked session cannot be swiped past by accident.
enum WatchPage: String, Hashable {
    case home
    case quota
}
