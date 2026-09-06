import Testing
import Foundation
import VibeBuddyKit
@testable import VibeBuddyMacCore

/// Budget / usage notices are chrome, not session cues: they answer only to the
/// quota category switch. The attention matrix is not consulted.
@Suite("Quota notice gating")
struct QuotaNoticeTests {

    @Test("Mac load of an old archive turns quota on; the wire form used by phones stays off")
    func macLoadDefaultsQuotaOn() throws {
        let archive = Data(#"{"enabled":["needs_approval","needs_answer","agent_stuck","agent_done"]}"#.utf8)
        let suite = "QuotaNoticeTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(archive, forKey: NotificationCategoryPrefs.defaultsKey)

        #expect(NotificationCategoryPrefs.loadMac(from: defaults).isEnabled(.quota))
        #expect(!NotificationCategoryPrefs.load(from: defaults).isEnabled(.quota))

        let uploaded = try JSONDecoder().decode(DeviceRegistrationPayload.self,
                                                from: Data(#"{"token":"t","categories":{"enabled":["needs_approval","agent_done"]}}"#.utf8))
        #expect(uploaded.categories?.isEnabled(.quota) == false)
    }

    @Test("a phone that never uploaded quota is not pushed; a phone that turned it on is")
    func phoneSwitchGatesPush() {
        let off = DeviceRegistrationPayload(token: "legacy")
        var prefs = NotificationCategoryPrefs.default
        prefs.set(.quota, enabled: true)
        let on = DeviceRegistrationPayload(token: "opted-in", categories: prefs)

        let skip = QuotaNoticeFanout.plan(devices: [off], apnsConfigured: true)
        #expect(skip.recipients.isEmpty)
        #expect(skip.skip == .category)

        let send = QuotaNoticeFanout.plan(devices: [off, on], apnsConfigured: true)
        #expect(send.recipients.map(\.token) == ["opted-in"])
        #expect(send.skip == nil)
    }
}
