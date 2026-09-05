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

    @Test("defaults: approvals, questions, failures and completions on; nudge and pairing off")
    func defaults() {
        let d = NotificationCategoryPrefs.default
        #expect(d.isEnabled(.needsApproval))
        #expect(d.isEnabled(.needsAnswer))
        #expect(d.isEnabled(.agentStuck))
        #expect(d.isEnabled(.agentDone))
        #expect(!d.isEnabled(.longWaitNudge))
        #expect(!d.isEnabled(.pairSuccess))
        #expect(Set(NotificationCategoryPrefs.displayOrder) == Set(NotificationSound.allCases))
    }

    @Test("filter keeps only enabled categories, in order")
    func filterDropsDisabled() {
        var prefs = NotificationCategoryPrefs.default
        prefs.set(.agentDone, enabled: false)
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
        prefs.set(.pairSuccess, enabled: true)
        prefs.set(.needsAnswer, enabled: false)
        prefs.save(to: defaults)
        #expect(NotificationCategoryPrefs.load(from: defaults) == prefs)

        defaults.set(Data("junk".utf8), forKey: NotificationCategoryPrefs.defaultsKey)
        #expect(NotificationCategoryPrefs.load(from: defaults) == .default)
    }

    @Test("the wire form is the list of enabled sound names")
    func wireForm() throws {
        let data = try JSONEncoder().encode(NotificationCategoryPrefs(enabled: [.agentDone]))
        #expect(String(decoding: data, as: UTF8.self) == #"{"enabled":["agent_done"]}"#)
    }
}
