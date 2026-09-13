import Foundation
import UserNotifications
import VibeBuddyKit
import WatchKit

/// Where a tapped notification lands.
///
/// Every notification the wrist shows is the iPhone's, mirrored. Its *buttons*
/// are answered by the iPhone — Apple routes a forwarded notification's action
/// back to the app that posted it — but its default tap opens this app, and
/// without a delegate it opens on whatever the home screen happens to lead
/// with. That is fine with one thing waiting and wrong with three: the buzz was
/// about a session, so the screen it opens should be that session's.
///
/// The delegate is registered at launch, before any scene exists, and the
/// store may not exist yet either (a cold launch from a notification). So the
/// router holds the one session id until something can open it.
@MainActor
final class WatchNotificationRouter {
    static let shared = WatchNotificationRouter()

    private var handler: ((String) -> Void)?
    private var pending: String?

    /// Open this session, or remember to once a store is listening.
    func open(sessionID: String) {
        guard !sessionID.isEmpty else { return }
        if let handler { handler(sessionID) } else { pending = sessionID }
    }

    /// The store is up. Anything that arrived first is delivered now.
    func attach(_ handler: @escaping (String) -> Void) {
        self.handler = handler
        if let pending {
            self.pending = nil
            handler(pending)
        }
    }
}

/// The app delegate exists for one reason: to be the notification centre's
/// delegate from the first moment of the process, which a SwiftUI scene cannot
/// promise.
final class WatchAppDelegate: NSObject, WKApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching() {
        UNUserNotificationCenter.current().delegate = self
    }

    /// The default tap on a mirrored notification. Only the session id is
    /// read from it — the notification's userInfo is data, not instructions,
    /// and the store re-derives everything about that session from the
    /// relayed state before it draws a single button.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier else { return }
        let userInfo = response.notification.request.content.userInfo
        guard let sessionID = userInfo[NotificationUserInfoKey.sessionId] as? String else { return }
        await MainActor.run { WatchNotificationRouter.shared.open(sessionID: sessionID) }
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
