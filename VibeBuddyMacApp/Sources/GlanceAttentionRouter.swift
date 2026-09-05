import AppKit
import VibeBuddyKit
import VibeBuddyMacCore

/// Routes each cue the `SoundPolicy` earns to the glance first: while the glance
/// is on screen the cue becomes a card under the notch (with the pack's sound),
/// and the system banner is not posted — the card is the banner. When the
/// glance is hidden the cue falls through to `UserNotificationsNotifier`
/// unchanged, so nothing is lost with the glance off.
final class GlanceAttentionRouter: AttentionNotifier, @unchecked Sendable {
    private let banners: UserNotificationsNotifier
    /// `nil` when the glance can't take the cue right now (hidden / not built).
    private let presentOnGlance: @MainActor (SoundAlert) -> Bool

    init(banners: UserNotificationsNotifier, presentOnGlance: @escaping @MainActor (SoundAlert) -> Bool) {
        self.banners = banners
        self.presentOnGlance = presentOnGlance
    }

    func notify(_ alert: SoundAlert) async -> LocalNotificationAttempt {
        // The user's "notify" switch governs cards the same way it governs
        // banners: off means no ping of either kind (the banner path skips too).
        guard Self.notificationsEnabled else { return await banners.notify(alert) }
        let shown = await MainActor.run { presentOnGlance(alert) }
        guard shown else { return await banners.notify(alert) }
        if Self.soundEnabled { CuePlayer.play(alert.sound) }
        return .scheduled()
    }

    /// A withdrawal names Notification Center identifiers. A card under the
    /// notch needs no telling: `GlanceCardQueue.tick` already drops a card whose
    /// session stopped waiting, so only the banner side is forwarded.
    func withdraw(_ identifiers: [String]) async {
        await banners.withdraw(identifiers)
    }

    private static var notificationsEnabled: Bool { flag("notifyOnNeedsResponse") }
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
        guard let url = Bundle.main.url(forResource: sound.rawValue, withExtension: "caf"),
              let cue = NSSound(contentsOf: url, byReference: true) else { return }
        playing?.stop()
        playing = cue
        cue.play()
    }
}
