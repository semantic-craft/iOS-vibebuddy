import Foundation
import UserNotifications
import VibeBuddyKit
import VibeBuddyMacCore

/// Posts a macOS banner with the sound pack's cue. A thin wrapper over
/// `UNUserNotificationCenter`; *which* cue and *when* are decided by
/// `SoundPolicy` (unit-tested), so this type stays pure system I/O.
final class UserNotificationsNotifier: NSObject, AttentionNotifier, UNUserNotificationCenterDelegate {
    private let center = UNUserNotificationCenter.current()

    override init() {
        super.init()
        center.delegate = self
    }

    /// Ask once for alert + sound permission. A denial just makes posting a no-op.
    func requestAuthorization() {
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func notify(_ alert: SoundAlert) {
        guard Self.flag("notifyOnNeedsResponse") else { return }   // Settings → master switch
        let (title, body) = Self.copy(for: alert)
        post(title: title, body: body, sound: alert.sound,
             id: "\(alert.sessionID)-\(alert.sound.rawValue)")
    }

    /// A phone just paired — the one chrome cue that isn't tied to a session.
    func confirmPairing(deviceName: String) {
        guard Self.flag("notifyOnNeedsResponse") else { return }
        post(title: String(localized: "Paired with \(deviceName)"),
             body: String(localized: "VibeBuddy is watching your sessions."),
             sound: .pairSuccess, id: "pair-success")
    }

    /// A session crossed the spend budget — a gentle heads-up (estimate).
    func notifyBudget(project: String, cost: String) {
        guard Self.flag("notifyOnNeedsResponse") else { return }
        post(title: String(localized: "\(project) over budget"),
             body: String(localized: "≈ \(cost) spent this session (estimate)"),
             sound: .longWaitNudge, id: "budget-\(project)")
    }

    private func post(title: String, body: String, sound: NotificationSound, id: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = Self.flag("playNotificationSound")
            ? UNNotificationSound(named: UNNotificationSoundName(rawValue: sound.fileName))
            : nil
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    /// Show the banner even though the menu-bar app runs as an accessory.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        Self.flag("playNotificationSound") ? [.banner, .sound] : [.banner]
    }

    /// A Bool default that treats an absent key as `true` (on by default).
    private static func flag(_ key: String) -> Bool {
        UserDefaults.standard.object(forKey: key) == nil ? true : UserDefaults.standard.bool(forKey: key)
    }

    /// Banner copy per cue, drawing on the session's own detail where it helps.
    private static func copy(for alert: SoundAlert) -> (title: String, body: String) {
        let session = alert.session
        let project = session.project
        switch alert.sound {
        case .needsApproval:
            return (String(localized: "\(project) needs approval"),
                    session.pendingApproval?.commandPreview ?? session.summary ?? String(localized: "Approve or deny"))
        case .needsAnswer:
            return (String(localized: "\(project) needs you"), session.summary ?? String(localized: "Waiting for your response"))
        case .longWaitNudge:
            return (String(localized: "\(project) is still waiting"), session.summary ?? String(localized: "Waiting for your response"))
        case .agentDone:
            return (String(localized: "\(project) finished"), session.summary ?? String(localized: "Task complete"))
        case .agentStuck:
            return (String(localized: "\(project) stopped"), session.summary ?? String(localized: "It may need a look"))
        case .pairSuccess:
            return (String(localized: "Paired"), String(localized: "VibeBuddy is watching your sessions."))
        }
    }
}
