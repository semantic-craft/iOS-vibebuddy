import Foundation
import Testing
import UserNotifications
import VibeBuddyKit
@testable import VibeBuddyMacCore

/// Mac 1.3.34 review: with VoiceOver on, a banner that posted fine but never
/// appeared (alert style None, provisional) skipped the card too, and VoiceOver
/// never read the cue.
@Suite("Attention routing")
struct AttentionRoutingTests {
    final class Surfaces: AttentionSurfaces, @unchecked Sendable {
        let voiceOver: Bool
        let appears: Bool
        let glanceVisible: Bool
        private let lock = NSLock()
        private var log: [String] = []

        init(voiceOver: Bool, appears: Bool, glanceVisible: Bool = true) {
            self.voiceOver = voiceOver
            self.appears = appears
            self.glanceVisible = glanceVisible
        }

        var calls: [String] { lock.withLock { log } }
        private func note(_ call: String) { lock.withLock { log.append(call) } }

        var notificationsEnabled: Bool { true }
        func voiceOverRunning() async -> Bool { voiceOver }
        func bannerAppears() async -> Bool { appears }
        func isStillCurrent(_ alert: SoundAlert) async -> Bool { true }
        func postBanner(_ alert: SoundAlert) async -> LocalNotificationAttempt { note("banner"); return .scheduled() }
        func presentCard(_ alert: SoundAlert) async -> Bool {
            guard glanceVisible else { return false }
            note("card"); return true
        }
        func playCue(_ alert: SoundAlert) async { note("sound") }
        func announce(_ alert: SoundAlert) async { note("announce") }
    }

    private let alert = Self.alert(.bannerSound)

    private static func alert(_ delivery: DeliveryLevel) -> SoundAlert {
        SoundAlert(
            session: AgentSession(id: "s", agent: .claudeCode, project: "p", status: .needsResponse,
                                  waitKind: .permission, statusSince: Date(timeIntervalSince1970: 0),
                                  updatedAt: Date(timeIntervalSince1970: 0)),
            sound: .needsApproval, delivery: delivery)
    }

    @Test("only an authorized, alerting style puts a banner on screen")
    func bannerVisibility() {
        #expect(BannerVisibility.appears(authorization: .authorized, alertStyle: .banner, alertSetting: .enabled))
        #expect(BannerVisibility.appears(authorization: .authorized, alertStyle: .alert, alertSetting: .enabled))
        #expect(!BannerVisibility.appears(authorization: .authorized, alertStyle: .none, alertSetting: .enabled))
        #expect(!BannerVisibility.appears(authorization: .authorized, alertStyle: .banner, alertSetting: .disabled))
        // Provisional is delivered quietly, straight to Notification Center.
        #expect(!BannerVisibility.appears(authorization: .provisional, alertStyle: .banner, alertSetting: .enabled))
        #expect(!BannerVisibility.appears(authorization: .denied, alertStyle: .banner, alertSetting: .enabled))
    }

    @Test("VoiceOver with a banner that would not appear: the card, spoken")
    func voiceOverSilentBannerFallsBackToCard() async {
        let surfaces = Surfaces(voiceOver: true, appears: false)
        let attempt = await AttentionRouting.route(alert, via: surfaces)
        #expect(attempt.outcome == .scheduled)
        #expect(surfaces.calls == ["card", "announce", "sound"])
    }

    @Test("VoiceOver with a banner that appears: the banner alone")
    func voiceOverVisibleBanner() async {
        let surfaces = Surfaces(voiceOver: true, appears: true)
        _ = await AttentionRouting.route(alert, via: surfaces)
        #expect(surfaces.calls == ["banner"])
    }

    @Test("VoiceOver, silent banner, glance hidden: spoken, and still filed")
    func voiceOverSilentBannerGlanceHidden() async {
        let surfaces = Surfaces(voiceOver: true, appears: false, glanceVisible: false)
        _ = await AttentionRouting.route(alert, via: surfaces)
        #expect(surfaces.calls == ["banner", "announce"])
    }

    @Test("VoiceOver, silent banner, list-only cue: the card, not spoken")
    func voiceOverListOnlyStaysQuiet() async {
        let surfaces = Surfaces(voiceOver: true, appears: false)
        _ = await AttentionRouting.route(Self.alert(.list), via: surfaces)
        #expect(surfaces.calls == ["card", "sound"])
    }
}
