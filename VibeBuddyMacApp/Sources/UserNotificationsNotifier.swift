import Foundation
import UserNotifications
import VibeBuddyKit
import VibeBuddyMacCore

/// Posts a macOS banner when a session needs the user. A thin wrapper over
/// `UNUserNotificationCenter`; *when* to fire is decided by `NotificationCoordinator`
/// (unit-tested), so this type stays pure system I/O.
final class UserNotificationsNotifier: NSObject, AttentionNotifier, UNUserNotificationCenterDelegate {
    private let center = UNUserNotificationCenter.current()

    override init() {
        super.init()
        center.delegate = self
    }

    /// Ask once for alert + sound permission. A denial just makes `notify` a no-op.
    func requestAuthorization() {
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func notify(_ session: AgentSession) {
        guard Self.flag("notifyOnNeedsResponse") else { return }   // Settings → Notifications
        let content = UNMutableNotificationContent()
        content.title = "\(session.project) needs you"
        content.body = session.summary ?? "Waiting for your response"
        content.sound = Self.flag("playNotificationSound") ? .default : nil
        // Keyed by session id: a still-waiting session won't stack duplicates.
        let request = UNNotificationRequest(identifier: session.id, content: content, trigger: nil)
        center.add(request)
    }

    /// Show the banner even though the menu-bar app runs as an accessory.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        Self.flag("playNotificationSound") ? [.banner, .sound] : [.banner]
    }

    /// A Bool default that treats an absent key as `true` (notifications on by default).
    private static func flag(_ key: String) -> Bool {
        UserDefaults.standard.object(forKey: key) == nil ? true : UserDefaults.standard.bool(forKey: key)
    }
}
