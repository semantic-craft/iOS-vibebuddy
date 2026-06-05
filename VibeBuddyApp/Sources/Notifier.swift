import Foundation
import UserNotifications
import VibeBuddyKit

/// Stable identifiers for the app's own notifications.
enum NotificationID {
    static let pairSuccess = "pair-success"
}

/// Fires a local notification carrying the sound pack's cue. Injectable so the
/// dashboard's notify logic can be driven by a fake in tests. *Which* cue and
/// *when* is decided by the shared `SoundPolicy`; this only renders it.
protocol AttentionNotifier: Sendable {
    func requestAuthorization()
    func notify(_ alert: SoundAlert)
    func confirmPairing()
}

struct LocalNotifier: AttentionNotifier {
    func requestAuthorization() {
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    func notify(_ alert: SoundAlert) {
        let (title, body) = Self.copy(for: alert)
        post(title: title, body: body, sound: alert.sound,
             id: "\(alert.sessionID)-\(alert.sound.rawValue)")
    }

    /// A fresh pairing just succeeded — the one chrome cue not tied to a session.
    func confirmPairing() {
        post(title: String(localized: "Connected"),
             body: String(localized: "VibeBuddy is watching your sessions."),
             sound: .pairSuccess, id: NotificationID.pairSuccess)
    }

    private func post(title: String, body: String, sound: NotificationSound, id: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = Self.soundOn
            ? UNNotificationSound(named: UNNotificationSoundName(rawValue: sound.fileName))
            : nil
        UNUserNotificationCenter.current()
            .add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    /// Sound on by default. Mute = sound off.
    private static var soundOn: Bool { SoundPrefs.playSound }

    /// Banner copy per cue.
    private static func copy(for alert: SoundAlert) -> (title: String, body: String) {
        let s = alert.session
        switch alert.sound {
        case .needsApproval:
            return (String(localized: "\(s.project) needs permission"),
                    s.pendingApproval?.commandPreview ?? s.summary ?? String(localized: "Approve or deny"))
        case .needsAnswer:
            return (String(localized: "\(s.project) needs you"),
                    s.summary ?? String(localized: "Waiting for your input"))
        case .longWaitNudge:
            return (String(localized: "\(s.project) is still waiting"),
                    s.summary ?? String(localized: "Waiting for your input"))
        case .agentDone:
            return (String(localized: "\(s.project) is done"),
                    s.summary ?? String(localized: "Task complete"))
        case .agentStuck:
            return (String(localized: "\(s.project) stopped"),
                    s.summary ?? String(localized: "Might need a look"))
        case .pairSuccess:
            return (String(localized: "Connected"),
                    String(localized: "VibeBuddy is watching your sessions."))
        }
    }
}
