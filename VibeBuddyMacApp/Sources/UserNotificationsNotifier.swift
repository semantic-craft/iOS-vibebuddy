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
        let content = UNMutableNotificationContent()
        content.title = "\(session.project) 需要你"
        content.body = session.summary ?? "等待你的响应"
        content.sound = .default
        // Keyed by session id: a still-waiting session won't stack duplicates.
        let request = UNNotificationRequest(identifier: session.id, content: content, trigger: nil)
        center.add(request)
    }

    /// Show the banner even though the menu-bar app runs as an accessory.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
