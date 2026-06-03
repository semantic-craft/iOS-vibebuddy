import Foundation
import UserNotifications
import VibeBuddyKit

/// Fires a local notification when a session needs the user. Injectable so the
/// dashboard's notify logic can be driven by a fake in tests.
protocol AttentionNotifier: Sendable {
    func requestAuthorization()
    func notify(_ session: AgentSession)
}

struct LocalNotifier: AttentionNotifier {
    func requestAuthorization() {
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    func notify(_ session: AgentSession) {
        let content = UNMutableNotificationContent()
        content.title = "\(session.project) 需要你"
        content.body = session.summary
            ?? (session.waitKind == .permission ? "需要权限确认" : "等待你的输入")
        content.sound = .default

        let id = "needs-\(session.id)-\(Int(session.statusSince.timeIntervalSince1970))"
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
