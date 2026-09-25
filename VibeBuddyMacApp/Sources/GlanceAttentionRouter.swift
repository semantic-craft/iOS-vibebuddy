import AppKit
import VibeBuddyKit
import VibeBuddyMacCore

/// The app's `AttentionSurfaces`: Notification Center through
/// `UserNotificationsNotifier`, the glance card through the model, VoiceOver
/// through an announcement. The routing itself is `AttentionRouting`.
final class GlanceAttentionRouter: AttentionNotifier, AttentionSurfaces, @unchecked Sendable {
    private let banners: UserNotificationsNotifier
    /// `false` when the glance can't take the cue right now (hidden / not built).
    private let presentOnGlance: @MainActor (SoundAlert) -> Bool

    init(banners: UserNotificationsNotifier, presentOnGlance: @escaping @MainActor (SoundAlert) -> Bool) {
        self.banners = banners
        self.presentOnGlance = presentOnGlance
    }

    func notify(_ alert: SoundAlert) async -> LocalNotificationAttempt {
        await AttentionRouting.route(alert, via: self)
    }

    var notificationsEnabled: Bool { Self.flag("notifyOnNeedsResponse") }

    func voiceOverRunning() async -> Bool {
        await MainActor.run { NSWorkspace.shared.isVoiceOverEnabled }
    }

    func bannerAppears() async -> Bool { await banners.bannerAppears() }

    func isStillCurrent(_ alert: SoundAlert) async -> Bool {
        await banners.validateCompletion?(alert) != false
    }

    func postBanner(_ alert: SoundAlert) async -> LocalNotificationAttempt { await banners.notify(alert) }

    func presentCard(_ alert: SoundAlert) async -> Bool { await MainActor.run { presentOnGlance(alert) } }

    func playCue(_ alert: SoundAlert) async {
        if Self.soundEnabled { CuePlayer.play(alert.sound) }
    }

    /// The banner's own words, spoken at high priority: an agent is waiting.
    func announce(_ alert: SoundAlert) async {
        await MainActor.run {
            let (title, body) = UserNotificationsNotifier.copy(for: alert)
            let text = body.isEmpty ? title : "\(title). \(body)"
            NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested, userInfo: [
                .announcement: text,
                .priority: NSAccessibilityPriorityLevel.high.rawValue,
            ])
        }
    }

    /// A withdrawal names Notification Center identifiers. A card under the
    /// notch needs no telling: `GlanceCardQueue.tick` already drops a card whose
    /// session stopped waiting, so only the banner side is forwarded.
    func withdraw(_ identifiers: [String]) async {
        await banners.withdraw(identifiers)
    }

    private static var soundEnabled: Bool { flag("playNotificationSound") }

    /// A Bool default that treats an absent key as `true` (on by default).
    private static func flag(_ key: String) -> Bool {
        UserDefaults.standard.object(forKey: key) == nil ? true : UserDefaults.standard.bool(forKey: key)
    }
}

/// Plays a cue from the bundled sound pack without going through Notification
/// Center — the glance card replaces the banner, but the ear still gets the cue.
enum CuePlayer {
    nonisolated(unsafe) private static var playing: NSSound?

    static func play(_ sound: NotificationSound) {
        guard E2ERunConfiguration.current?.audioEnabled ?? true,
              let url = Bundle.main.url(forResource: sound.rawValue, withExtension: "caf"),
              let cue = NSSound(contentsOf: url, byReference: true) else { return }
        playing?.stop()
        playing = cue
        cue.play()
    }
}
