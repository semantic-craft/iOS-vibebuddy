import Foundation
import UserNotifications
import VibeBuddyKit

/// Whether a banner this app posts now is put in front of the user — on
/// screen, where VoiceOver reads it — rather than only filed in Notification
/// Center. A successful `add` says nothing about that, so the VoiceOver route
/// asks this before trusting a banner to carry the cue:
/// - provisional authorization delivers quietly: no banner, no sound, only
///   Notification Center's history (Apple, "Asking permission to use
///   notifications");
/// - alert style None, or alerts switched off, files the notification without
///   showing it.
/// A Focus that silences the app is not visible here: the only public reader,
/// `INFocusStatusCenter`, needs a permission prompt of its own and says only
/// that some Focus is on (docs/planning/backlog/voiceover-alerts/issues/01).
public enum BannerVisibility {
    public static func appears(
        authorization: UNAuthorizationStatus,
        alertStyle: UNAlertStyle,
        alertSetting: UNNotificationSetting
    ) -> Bool {
        authorization == .authorized && alertStyle != .none && alertSetting == .enabled
    }
}

/// Where a Mac cue can land. The app backs it with Notification Center, the
/// notch glance and VoiceOver; tests back it with a script.
public protocol AttentionSurfaces: Sendable {
    /// The user's "notify" switch. Off means no ping of either kind: the cue is
    /// handed to the banner side, which skips it too.
    var notificationsEnabled: Bool { get }
    func voiceOverRunning() async -> Bool
    /// `BannerVisibility` over the live notification settings.
    func bannerAppears() async -> Bool
    /// False when a completion cue went stale before it could be shown.
    func isStillCurrent(_ alert: SoundAlert) async -> Bool
    func postBanner(_ alert: SoundAlert) async -> LocalNotificationAttempt
    /// Put the cue on the glance under the notch; false while the glance is hidden.
    func presentCard(_ alert: SoundAlert) async -> Bool
    /// The card replaces the banner, not its sound.
    func playCue(_ alert: SoundAlert) async
    /// Have VoiceOver speak the cue. Neither a card nor a banner that does not
    /// appear is ever read on its own.
    func announce(_ alert: SoundAlert) async
}

/// Routes each cue to the glance first: while the glance is on screen the cue
/// becomes a card under the notch (with the pack's sound) and no banner is
/// posted — the card is the banner. With the glance hidden the cue falls
/// through to a banner, so nothing is lost with the glance off.
///
/// With VoiceOver running the banner goes first, because VoiceOver reads a
/// banner and Notification Center keeps it, while a card folds away. That only
/// holds for a banner that actually appears, so a banner the settings would
/// file silently — or one that fails to post — is not trusted: the cue takes
/// the card route and VoiceOver is asked to speak it, unless the cue is
/// list-only.
public enum AttentionRouting {
    public static func route(_ alert: SoundAlert, via surfaces: some AttentionSurfaces) async -> LocalNotificationAttempt {
        guard surfaces.notificationsEnabled else { return await surfaces.postBanner(alert) }
        guard await surfaces.isStillCurrent(alert) else { return .skipped }
        let voiceOver = await surfaces.voiceOverRunning()
        if voiceOver, await surfaces.bannerAppears() {
            let banner = await surfaces.postBanner(alert)
            guard banner.outcome == .failed else { return banner }
        }
        // Spoken only once the cue has landed somewhere, and only when it was
        // meant to interrupt: a list-only cue stays as quiet as its banner would.
        let speak = voiceOver && alert.delivery.interrupts
        guard await surfaces.presentCard(alert) else {
            let banner = await surfaces.postBanner(alert)
            if speak, banner.shouldRecord { await surfaces.announce(alert) }
            return banner
        }
        if speak { await surfaces.announce(alert) }
        await surfaces.playCue(alert)
        return .scheduled()
    }
}
