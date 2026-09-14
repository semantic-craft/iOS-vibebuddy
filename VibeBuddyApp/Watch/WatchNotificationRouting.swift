import Foundation
import UserNotifications
import VibeBuddyKit
import WatchKit

/// Where a tapped notification lands.
///
/// Notifications are mirrored from the iPhone. Foreground actions run where
/// selected; background actions belong to the notification's original target.
/// The default tap is expected to open this app, and
/// without a delegate it opens on whatever the home screen happens to lead
/// with. That is fine with one thing waiting and wrong with three: the buzz was
/// about a session, so the screen it opens should be that session's.
///
/// The delegate is registered at launch, before any scene exists, and the
/// store may not exist yet either (a cold launch from a notification). So the
/// router holds the session id until the main window is active. The window
/// refreshes the relayed state before it lets the router present the target.
/// The app delegate exists for one reason: to be the notification centre's
/// delegate from the first moment of the process, which a SwiftUI scene cannot
/// promise.
final class WatchAppDelegate: NSObject, WKApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching() {
        UNUserNotificationCenter.current().delegate = self
        Task { @MainActor in WatchNavigationDiagnostics.shared.record("delegate.ready") }
    }

    /// The default tap on a mirrored notification. Only the session id is
    /// read from it — the notification's userInfo is data, not instructions,
    /// and the store re-derives everything about that session from the
    /// relayed state before it draws a single button.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping @Sendable () -> Void
    ) {
        // Complete the OS callback independently of main-window presentation.
        // Extract Sendable values before crossing to the UI actor.
        let isDefault = response.actionIdentifier == UNNotificationDefaultActionIdentifier
        let sessionID = response.notification.request.content.userInfo[NotificationUserInfoKey.sessionId] as? String
        Task { @MainActor in
            // Save the target before releasing the OS background execution
            // opportunity. This does not wait for a window or navigation.
            defer { completionHandler() }
            WatchNavigationDiagnostics.shared.record(isDefault ? "notification.default" : "notification.action")
            guard isDefault else { return }
            guard let sessionID, !sessionID.isEmpty else {
                WatchNavigationDiagnostics.shared.record("notification.missing-target")
                return
            }
            if let state = WatchComplicationStore.loadState()?.state,
               let source = state.sourceID, let epoch = state.pairingEpoch {
                let intent = WatchNotificationIntent(link: WatchTaskLink(sourceID: source,
                    pairingEpoch: epoch, sessionID: sessionID, completionID: state.task(sessionID)?.completionID))
                if let data = try? JSONEncoder().encode(intent) {
                    UserDefaults.standard.set(data, forKey: "watch.pendingNotificationIntent")
                    WatchNavigationDiagnostics.shared.record("notification.target-saved")
                }
            }
            WatchNotificationRouter.shared.open(sessionID: sessionID)
            WatchNavigationDiagnostics.shared.record("notification.target-enqueued")
        }
    }

    /// A mirrored notification arriving while this app is on screen. The
    /// screen already shows the session, and the store taps out the boundary
    /// itself (`WatchStateStore.feel`), so a banner on top would say the same
    /// thing twice. Same outcome as having no delegate at all, made explicit.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        []
    }
}
