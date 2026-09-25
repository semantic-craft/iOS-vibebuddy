import SwiftUI
import WatchKit
import WidgetKit
import VibeBuddyKit

@main
struct VibeBuddyWatchApp: App {
    /// Owns the notification-centre delegate from process start, so a tap on
    /// a mirrored notification opens the session it was about.
    @WKApplicationDelegateAdaptor(WatchAppDelegate.self) private var delegate
    @StateObject private var store = WatchStateStore()

    var body: some Scene {
        WindowGroup {
            WatchWindow(store: store)
        }

        // These scenes supply the long-look content; the buttons under it are
        // the shared categories', and a tap on one arrives in WatchAppDelegate.
        WKNotificationScene(controller: WatchNotificationController.self,
                            category: NotificationCategoryID.approval.rawValue)
        WKNotificationScene(controller: WatchNotificationController.self,
                            category: NotificationCategoryID.question.rawValue)
    }
}

/// The window's contents, and the only place that decides the app is being
/// looked at.
///
/// `scenePhase` is read here rather than on the `App`, where it is the
/// *aggregate* of every scene. Now that notification scenes exist, an aggregate
/// read would report a long look opening as the app coming forward — turning on
/// the in-app haptics and pulling the relay context in the middle of a
/// notification. Read from inside a view, the phase is that view's own scene.
private struct WatchWindow: View {
    @ObservedObject var store: WatchStateStore
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        WatchRootView(store: store)
            .onOpenURL { url in
                WatchNavigationDiagnostics.shared.record("entry.url")
                if !WatchNotificationRouter.shared.openActivityURL(url) {
                    store.openTask(url)
                }
            }
            .onContinueUserActivity(NSUserActivityTypeLiveActivity) { activity in
                WatchNavigationDiagnostics.shared.record("entry.live-activity")
                store.openLiveActivity(activity.userInfo?[WidgetCenter.UserInfoKey.activityID] as? String)
            }
            .overlay {
                if store.isOpeningActivity {
                    VStack(spacing: 12) {
                        ProgressView("Opening task…")
                        Button("Cancel") { store.cancelPendingNavigation() }
                    }
                    .padding().background(.black, in: RoundedRectangle(cornerRadius: 16))
                }
            }
            .alert("Unable to open task", isPresented: Binding(
                get: { store.activityOpenError != nil },
                set: { if !$0 { store.activityOpenError = nil } }
            )) {
                Button("OK", role: .cancel) { store.activityOpenError = nil }
            } message: {
                Text(LocalizedStringKey(store.activityOpenError ?? ""))
            }
            // `initial: true` because a phase that is already `.active` when the
            // window appears never arrives as a change, and nothing else would
            // ever tell the store the wrist is looking.
            .onChange(of: scenePhase, initial: true) { _, phase in
                if phase == .active {
                    store.becameActive()
                    // Refresh the relay before resolving the tapped session,
                    // and present only from the active main window.
                    WatchNotificationRouter.shared.setWindowActive(true)
                } else {
                    WatchNotificationRouter.shared.setWindowActive(false)
                    store.resignedActive()
                }
            }
            .sheet(item: $store.quotaSelection) { selection in
                TimelineView(.periodic(from: .now, by: 5)) { context in
                    if let state = store.state {
                        WatchQuotaView(state: state,
                                       connection: state.connection(now: context.date, phoneReachable: store.isPhoneReachable),
                                       now: context.date, selection: selection)
                    } else {
                        WatchNoDataView()
                    }
                }
            }
            .sheet(item: $store.taskLink, onDismiss: {
                WatchNavigationDiagnostics.shared.record("detail.dismissed")
            }) { link in
                WatchTaskDetailView(store: store, link: link)
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
