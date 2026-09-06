import Testing
import Foundation
@testable import VibeBuddyKit

/// The category switches: which cues a device wants at all, applied after the
/// sounding rules and independent of Focus mode.
@Suite("NotificationCategoryPrefs")
struct NotificationCategoriesTests {

    private func alert(_ sound: NotificationSound) -> SoundAlert {
        let t = Date(timeIntervalSince1970: 0)
        return SoundAlert(session: AgentSession(id: sound.rawValue, agent: .claudeCode, project: "p",
                                                status: .done, statusSince: t, updatedAt: t),
                          sound: sound)
    }

    @Test("phone defaults: approvals, questions, failures and completions on; nudge, pairing and quota off")
    func defaults() {
        let d = NotificationCategoryPrefs.default
        #expect(d.isEnabled(NotificationSound.needsApproval))
        #expect(d.isEnabled(NotificationSound.needsAnswer))
        #expect(d.isEnabled(NotificationSound.agentStuck))
        #expect(d.isEnabled(NotificationSound.agentDone))
        #expect(!d.isEnabled(NotificationSound.longWaitNudge))
        #expect(!d.isEnabled(NotificationSound.pairSuccess))
        #expect(!d.isEnabled(.quota))
        #expect(Set(NotificationCategoryPrefs.displayOrder) == Set(NotificationCategory.allCases))
    }

    @Test("Mac defaults match the phone set, with quota on")
    func macDefaults() {
        let d = NotificationCategoryPrefs.macDefault
        #expect(d.isEnabled(NotificationSound.needsApproval))
        #expect(d.isEnabled(NotificationSound.needsAnswer))
        #expect(d.isEnabled(NotificationSound.agentStuck))
        #expect(d.isEnabled(NotificationSound.agentDone))
        #expect(!d.isEnabled(NotificationSound.longWaitNudge))
        #expect(!d.isEnabled(NotificationSound.pairSuccess))
        #expect(d.isEnabled(.quota))
    }

    @Test("filter keeps only enabled session categories, in order")
    func filterDropsDisabled() {
        var prefs = NotificationCategoryPrefs.default
        prefs.set(NotificationSound.agentDone, enabled: false)
        let kept = prefs.filter([alert(.agentDone), alert(.needsApproval), alert(.longWaitNudge), alert(.agentStuck)])
        #expect(kept.map(\.sound) == [.needsApproval, .agentStuck])
    }

    @Test("round-trips through JSON and UserDefaults; unreadable storage falls back to the default")
    func persistence() throws {
        let suite = "NotificationCategoriesTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        #expect(NotificationCategoryPrefs.load(from: defaults) == .default)
        var prefs = NotificationCategoryPrefs.default
        prefs.set(NotificationSound.pairSuccess, enabled: true)
        prefs.set(NotificationSound.needsAnswer, enabled: false)
        prefs.set(.quota, enabled: true)
        prefs.save(to: defaults)
        #expect(NotificationCategoryPrefs.load(from: defaults) == prefs)

        defaults.set(Data("junk".utf8), forKey: NotificationCategoryPrefs.defaultsKey)
        #expect(NotificationCategoryPrefs.load(from: defaults) == .default)
    }

    @Test("an old archive without a quota key decodes as the phone default (off)")
    func missingQuotaKeyIsPhoneDefault() throws {
        let data = Data(#"{"enabled":["needs_approval","needs_answer","agent_stuck","agent_done"]}"#.utf8)
        let prefs = try JSONDecoder().decode(NotificationCategoryPrefs.self, from: data)
        #expect(prefs.isEnabled(NotificationSound.needsApproval))
        #expect(prefs.isEnabled(NotificationSound.agentDone))
        #expect(!prefs.isEnabled(.quota))

        let suite = "NotificationCategoriesTests.phone.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(data, forKey: NotificationCategoryPrefs.defaultsKey)
        #expect(!NotificationCategoryPrefs.load(from: defaults).isEnabled(.quota))
    }

    @Test("an old Mac archive without a quota key decodes as the Mac default (on)")
    func missingQuotaKeyIsMacDefaultOnLoadMac() throws {
        let data = Data(#"{"enabled":["needs_approval","needs_answer","agent_stuck","agent_done"]}"#.utf8)
        let suite = "NotificationCategoriesTests.mac.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(data, forKey: NotificationCategoryPrefs.defaultsKey)
        #expect(NotificationCategoryPrefs.loadMac(from: defaults).isEnabled(.quota))
        #expect(NotificationCategoryPrefs.loadMac(from: defaults).isEnabled(NotificationSound.needsApproval))

        defaults.removePersistentDomain(forName: suite)
        #expect(NotificationCategoryPrefs.loadMac(from: defaults) == .macDefault)
    }

    @Test("an explicit quota key wins over the platform default")
    func explicitQuotaKeyWins() throws {
        let off = Data(#"{"enabled":["needs_approval"],"quota":false}"#.utf8)
        let on = Data(#"{"enabled":["needs_approval"],"quota":true}"#.utf8)
        #expect(try JSONDecoder().decode(NotificationCategoryPrefs.self, from: off).isEnabled(.quota) == false)
        #expect(try JSONDecoder().decode(NotificationCategoryPrefs.self, from: on).isEnabled(.quota) == true)

        let suite = "NotificationCategoriesTests.explicit.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(off, forKey: NotificationCategoryPrefs.defaultsKey)
        #expect(!NotificationCategoryPrefs.loadMac(from: defaults).isEnabled(.quota))
        defaults.set(on, forKey: NotificationCategoryPrefs.defaultsKey)
        #expect(NotificationCategoryPrefs.load(from: defaults).isEnabled(.quota))
    }

    @Test("the wire form is the list of enabled sound names plus the quota key")
    func wireForm() throws {
        let data = try JSONEncoder().encode(NotificationCategoryPrefs(enabled: [.agentDone]))
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(object?["enabled"] as? [String] == ["agent_done"])
        #expect(object?["quota"] as? Bool == false)
    }
}
