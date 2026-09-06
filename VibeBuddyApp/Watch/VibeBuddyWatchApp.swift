import SwiftUI
import VibeBuddyKit

@main
struct VibeBuddyWatchApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var store = WatchStateStore()

    var body: some Scene {
        WindowGroup {
            WatchRootView(store: store)
                .onOpenURL { store.openTask($0) }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { store.becameActive() }
                }
                .sheet(item: $store.taskLink) { link in
                    WatchTaskDetailView(store: store, link: link)
                }
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
