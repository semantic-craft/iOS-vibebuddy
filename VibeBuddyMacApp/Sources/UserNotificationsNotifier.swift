import Foundation
import UserNotifications
import VibeBuddyKit
import VibeBuddyMacCore

/// Posts a macOS notification with the sound pack's cue. A thin wrapper over
/// `UNUserNotificationCenter`; *which* cue, *when* and *how loud* are decided
/// by `SoundPolicy` (unit-tested), so this type stays pure system I/O: it maps
/// the alert's `DeliveryLevel` onto sound / banner / list-only presentation.
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

    func notify(_ alert: SoundAlert) async -> LocalNotificationAttempt {
        guard Self.flag("notifyOnNeedsResponse"), alert.delivery != .drop else { return .skipped }
        let authorized = await isAuthorized()
        let (title, body) = Self.copy(for: alert)
        let classified = LocalNotificationDelivery.classify(authorized: authorized, scheduleError: nil)
        guard classified.outcome == .scheduled else {
            return .failed(reason: classified.failureReason ?? "permissionDenied")
        }
        do {
            // The same identifier the phone uses, so the ledger can name it.
            try await post(title: title, body: body, sound: alert.sound, delivery: alert.delivery,
                           id: alert.notificationID)
            return .scheduled()
        } catch {
            return .failed(reason: LocalNotificationDelivery.classify(
                authorized: true, scheduleError: error).failureReason ?? "scheduleFailed")
        }
    }

    func withdraw(_ identifiers: [String]) async {
        guard !identifiers.isEmpty else { return }
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
    }

    /// A phone just paired — the one chrome cue that isn't tied to a session.
    func confirmPairing(deviceName: String) {
        guard Self.flag("notifyOnNeedsResponse"),
              NotificationCategoryPrefs.load().isEnabled(.pairSuccess) else { return }
        enqueue(title: String(localized: "Paired with \(deviceName)"),
                body: String(localized: "VibeBuddy is watching your sessions."),
                sound: .pairSuccess, id: "pair-success")
    }

    /// A session crossed the spend budget — a gentle heads-up (estimate).
    func notifyBudget(project: String, cost: String) {
        guard Self.flag("notifyOnNeedsResponse") else { return }
        enqueue(title: String(localized: "\(project) over budget"),
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
        enqueue(
            title: String(localized: "\(provider.displayName) usage reached \(threshold)%"),
            body: String(localized: "\(window.usedPercent)% used in the \(duration) window.\(reset)"),
            sound: .longWaitNudge,
            id: "\(provider.rawValue)-usage-\(window.kind.rawValue)-\(window.resetsAt?.timeIntervalSince1970 ?? 0)"
        )
    }

    private func enqueue(title: String, body: String, sound: NotificationSound, id: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = Self.flag("playNotificationSound")
            ? UNNotificationSound(named: UNNotificationSoundName(rawValue: sound.fileName))
            : nil
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    private func isAuthorized() async -> Bool {
        switch await center.notificationSettings().authorizationStatus {
        case .authorized, .provisional: true
        default: false
        }
    }

    private static let deliveryKey = "delivery"

    private func post(title: String, body: String, sound: NotificationSound,
                      delivery: DeliveryLevel, id: String) async throws {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = delivery.makesSound && Self.flag("playNotificationSound")
            ? UNNotificationSound(named: UNNotificationSoundName(rawValue: sound.fileName))
            : nil
        // Carried to `willPresent`, which is where an accessory app actually
        // decides what the system shows.
        content.userInfo = [Self.deliveryKey: delivery.rawValue]
        if delivery == .list { content.interruptionLevel = .passive }
        try await center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    /// Present according to the cue's delivery level, even though the menu-bar
    /// app runs as an accessory: a list-only cue lands in Notification Center
    /// without a banner; everything else banners *and* stays in the list, so
    /// what was said can still be found later. Chrome cues (pairing, budget,
    /// usage) carry no level and are shown in full.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        let raw = notification.request.content.userInfo[Self.deliveryKey] as? Int
        let level = raw.flatMap(DeliveryLevel.init(rawValue:)) ?? .bannerSound
        switch level {
        case .drop, .list:
            return [.list]
        case .banner:
            return [.banner, .list]
        case .bannerSound:
            return Self.flag("playNotificationSound") ? [.banner, .list, .sound] : [.banner, .list]
        }
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
    /// The same words the phone puts on its banner and the push carries:
    /// one `PushCopy` for all three surfaces, localized here through this
    /// app's own string table (the keys are the English source text).
    private static func copy(for alert: SoundAlert) -> (title: String, body: String) {
        let c = PushCopy.copy(for: alert.sound, session: alert.session)
        let title = String(format: NSLocalizedString(c.titleKey, comment: ""), locale: .current,
                           arguments: c.titleArgs)
        let body = c.bodyKey.map { NSLocalizedString($0, comment: "") } ?? c.body
        return (title, body)
    }
}
