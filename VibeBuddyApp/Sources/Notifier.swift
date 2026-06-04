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
        post(title: "已连接", body: "VibeBuddy 正在盯着你的会话。",
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

    /// Treats an absent key as `true` — sound on by default. Mute = sound off.
    private static var soundOn: Bool {
        UserDefaults.standard.object(forKey: "playNotificationSound") == nil
            ? true : UserDefaults.standard.bool(forKey: "playNotificationSound")
    }

    /// Banner copy per cue, in the app's Chinese voice.
    private static func copy(for alert: SoundAlert) -> (title: String, body: String) {
        let s = alert.session
        switch alert.sound {
        case .needsApproval:
            return ("\(s.project) 需要权限", s.pendingApproval?.commandPreview ?? s.summary ?? "批准或拒绝")
        case .needsAnswer:
            return ("\(s.project) 需要你", s.summary ?? "等待你的输入")
        case .longWaitNudge:
            return ("\(s.project) 还在等你", s.summary ?? "等待你的输入")
        case .agentDone:
            return ("\(s.project) 完成了", s.summary ?? "任务完成")
        case .agentStuck:
            return ("\(s.project) 停下了", s.summary ?? "可能需要看一下")
        case .pairSuccess:
            return ("已连接", "VibeBuddy 正在盯着你的会话。")
        }
    }
}
