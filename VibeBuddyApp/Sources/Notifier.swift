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
    /// Take back notifications whose session is no longer waiting. They are
    /// mirrored on the Watch, where a banner for an answered request is worse
    /// than no banner: it opens onto a session the wrist no longer lists.
    func withdraw(_ identifiers: [String])
    func confirmPairing()
}

struct LocalNotifier: AttentionNotifier {
    func requestAuthorization() {
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    func notify(_ alert: SoundAlert) {
        let (title, body) = Self.copy(for: alert)
        // The identifier the Mac's push uses as its collapse id: whichever
        // channel gets there first, iOS keeps one notification, and the Watch
        // mirrors one.
        post(title: title, body: body, sound: alert.sound, delivery: alert.delivery,
             id: alert.notificationID, sessionID: alert.sessionID)
    }

    func withdraw(_ identifiers: [String]) {
        guard !identifiers.isEmpty else { return }
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
    }

    /// A fresh pairing just succeeded — the one chrome cue not tied to a session.
    func confirmPairing() {
        post(title: String(localized: "Connected"),
             body: String(localized: "VibeBuddy is watching your sessions."),
             sound: .pairSuccess, id: NotificationID.pairSuccess)
    }

    private func post(title: String, body: String, sound: NotificationSound,
                      delivery: DeliveryLevel = .bannerSound,
                      id: String, sessionID: String? = nil) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = delivery.makesSound && Self.soundOn
            ? UNNotificationSound(named: UNNotificationSoundName(rawValue: sound.fileName))
            : nil
        // A list-only cue is filed in Notification Center without a banner.
        if delivery == .list { content.interruptionLevel = .passive }
        // Everything said about one session groups and opens as that session,
        // on the phone and on the wrist alike.
        if let sessionID {
            content.threadIdentifier = sessionID
            content.targetContentIdentifier = sessionID
            content.userInfo = ["sessionId": sessionID]
        }
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
