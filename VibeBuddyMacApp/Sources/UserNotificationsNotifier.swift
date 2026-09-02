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

    /// Account quota alert. This is separate from session-state sounds and is
    /// only called for a fresh, non-stale threshold crossing.
    func notifyUsage(
        provider: AccountUsageProvider,
        window: AccountUsageWindow,
        threshold: Int
    ) {
        guard Self.flag("notifyOnNeedsResponse"),
              !NotificationQuietMode.isEffective() else { return }
        let duration = window.windowDurationMinutes.map(Self.durationText) ?? String(localized: "quota")
        let reset = window.resetsAt.map {
            String(localized: " Resets \($0.formatted(date: .abbreviated, time: .shortened)).")
        } ?? ""
        post(
            title: String(localized: "\(provider.displayName) usage reached \(threshold)%"),
            body: String(localized: "\(window.usedPercent)% used in the \(duration) window.\(reset)"),
            sound: .longWaitNudge,
            id: "\(provider.rawValue)-usage-\(window.kind.rawValue)-\(window.resetsAt?.timeIntervalSince1970 ?? 0)"
        )
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

    private static func durationText(_ minutes: Int) -> String {
        if minutes % 10_080 == 0 { return String(localized: "\(minutes / 10_080) week") }
        if minutes % 1_440 == 0 { return String(localized: "\(minutes / 1_440) day") }
        if minutes % 60 == 0 { return String(localized: "\(minutes / 60) hour") }
        return String(localized: "\(minutes) minute")
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
