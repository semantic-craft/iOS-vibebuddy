import Testing
import Foundation
@testable import VibeBuddyKit

/// The wrist's vocabulary and its mute rules, as pure logic over relayed states:
/// which boundary earns a rhythm, which rhythm it is, and when the wrist stays
/// still. Mirrors `SoundPolicyTests` — only boundaries speak, and a backlog
/// never does.
@Suite("WatchHaptics")
struct WatchHapticsTests {

    private func session(_ id: String, _ status: SessionStatus,
                         wait: WaitKind? = nil,
                         failed: Bool? = nil,
                         unread: Bool = false,
                         since: TimeInterval = 0) -> AgentSession {
        AgentSession(id: id, agent: .codex, project: id, status: status,
                     waitKind: wait,
                     pendingApproval: wait == .permission
                        ? PendingApproval(id: id + "-approval", tool: "Bash",
                                          commandPreview: "ls", command: "ls") : nil,
                     pendingQuestion: wait == .question
                        ? PendingQuestion(id: id + "-q", prompt: "Which one?") : nil,
                     failed: failed, hasUnreadCompletion: unread,
                     attention: .followed,
                     statusSince: Date(timeIntervalSince1970: since),
                     updatedAt: Date(timeIntervalSince1970: since))
    }

    private func state(_ sessions: [AgentSession], quotas: [ProviderQuota] = [],
                       now: TimeInterval = 100) -> WatchDashboardState {
        var projected = WatchDashboardProjection.make(
            snapshot: Snapshot(sessions: sessions, serverTime: Date(timeIntervalSince1970: now),
                               sourceID: "mac-a"),
            quotas: quotas, relay: .live, now: Date(timeIntervalSince1970: now))
        projected.pairingEpoch = "epoch-1"
        return projected
    }

    private func quota(_ provider: AccountUsageProvider, remaining: Int?,
                       now: TimeInterval = 100) -> ProviderQuota {
        ProviderQuota(provider: provider, weeklyRemainingPercent: remaining,
                      weeklyResetsAt: Date(timeIntervalSince1970: now + 86_400),
                      weeklyWindowDurationMinutes: 10_080,
                      observedAt: Date(timeIntervalSince1970: now))
    }

    private var allOn: NotificationCategoryPrefs {
        NotificationCategoryPrefs(enabled: Set(NotificationSound.allCases), quota: true)
    }

    // MARK: The vocabulary

    @Test("four events, four rhythms")
    func rhythms() {
        #expect(WatchHaptics.beats(for: .needsYou) == [.long, .long, .long, .long, .long])
        #expect(WatchHaptics.beats(for: .done) == [.short])
        #expect(WatchHaptics.beats(for: .error) == [.long, .long])
        #expect(WatchHaptics.beats(for: .quotaLow) == [.short, .long])
    }

    @Test("a permission and a question are the same thing to a wrist")
    func categoriesFoldToEvents() {
        #expect(WatchHaptics.event(for: .needsApproval) == .needsYou)
        #expect(WatchHaptics.event(for: .needsAnswer) == .needsYou)
        #expect(WatchHaptics.event(for: .agentStuck) == .error)
        #expect(WatchHaptics.event(for: .agentDone) == .done)
        #expect(WatchHaptics.event(for: .quota) == .quotaLow)
        // Not wrist events: a nudge repeats what was already said, pairing is chrome.
        #expect(WatchHaptics.event(for: .longWaitNudge) == nil)
        #expect(WatchHaptics.event(for: .pairSuccess) == nil)
        #expect(WatchHaptics.rhythm(for: .longWaitNudge, categories: allOn, quiet: false).isEmpty)
        #expect(WatchHaptics.rhythm(for: .pairSuccess, categories: allOn, quiet: false).isEmpty)
    }

    @Test("long beats sit further apart than short ones, so a count survives")
    func spacing() {
        #expect(WristHapticBeat.short.spacing < WristHapticBeat.long.spacing)
        #expect(WristHapticBeat.short.spacing > 0)
    }

    // MARK: Muting

    @Test("a switched-off category is silent")
    func categorySwitch() {
        var prefs = allOn
        prefs.set(NotificationSound.needsAnswer, enabled: false)
        #expect(WatchHaptics.rhythm(for: .needsAnswer, categories: prefs, quiet: false).isEmpty)
        // The other half of the same wrist event is untouched.
        #expect(WatchHaptics.rhythm(for: .needsApproval, categories: prefs, quiet: false)
                == [.long, .long, .long, .long, .long])
    }

    @Test("Quiet silences the session cues and leaves quota alone")
    func quiet() {
        for category in [NotificationCategory.needsApproval, .needsAnswer, .agentStuck, .agentDone] {
            #expect(WatchHaptics.rhythm(for: category, categories: allOn, quiet: true).isEmpty,
                    "\(category) should be silent in Quiet")
        }
        #expect(WatchHaptics.rhythm(for: .quota, categories: allOn, quiet: true) == [.short, .long])
    }

    @Test("quota answers only to its own switch")
    func quotaSwitch() {
        var off = allOn
        off.quota = false
        #expect(WatchHaptics.rhythm(for: .quota, categories: off, quiet: false).isEmpty)
        #expect(WatchHaptics.rhythm(for: .quota, categories: off, quiet: true).isEmpty)
    }

    @Test("the phone default leaves the four session cues audible and quota off")
    func relayDefault() {
        let state = state([])
        #expect(state.categories == nil)
        #expect(state.effectiveCategories == .default)
        #expect(!state.isQuiet(at: Date(timeIntervalSince1970: 100)))
        #expect(WatchHaptics.rhythm(for: .needsApproval, categories: state.effectiveCategories,
                                    quiet: false) == [.long, .long, .long, .long, .long])
        #expect(WatchHaptics.rhythm(for: .quota, categories: state.effectiveCategories,
                                    quiet: false).isEmpty)
    }

    @Test("Quiet is decided from relayed settings against the Watch's own clock")
    func quietFromSettings() {
        var relayed = state([])
        relayed.quiet = WatchQuietSettings(manual: false,
                                           hours: QuietHours(enabled: true, startHour: 22, endHour: 8))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let night = Date(timeIntervalSince1970: 23 * 3_600)   // 23:00 UTC
        let noon = Date(timeIntervalSince1970: 12 * 3_600)
        #expect(relayed.quiet?.isQuiet(at: night, calendar: calendar) == true)
        #expect(relayed.quiet?.isQuiet(at: noon, calendar: calendar) == false)
        relayed.quiet = WatchQuietSettings(manual: true)
        #expect(relayed.quiet?.isQuiet(at: noon, calendar: calendar) == true)
    }

    // MARK: Transitions

    @Test("the state already on screen at launch is history, not news")
    func firstStateIsSilent() {
        var transitions = WatchHapticTransitions()
        let waiting = state([session("a", .needsResponse, wait: .permission)])
        #expect(transitions.advance(to: waiting, now: Date(timeIntervalSince1970: 100)).isEmpty)
    }

    @Test("a session entering a wait earns the cue exactly once")
    func waitEntry() {
        var transitions = WatchHapticTransitions()
        let now = Date(timeIntervalSince1970: 100)
        _ = transitions.advance(to: state([session("a", .working)]), now: now)

        let waiting = state([session("a", .needsResponse, wait: .permission)])
        #expect(transitions.advance(to: waiting, now: now) == [.needsApproval])
        // The same wait, said again: silence.
        #expect(transitions.advance(to: waiting, now: now).isEmpty)
    }

    @Test("leaving and re-entering a wait is a new transition")
    func reEntry() {
        var transitions = WatchHapticTransitions()
        let now = Date(timeIntervalSince1970: 100)
        _ = transitions.advance(to: state([session("a", .working)]), now: now)
        #expect(transitions.advance(to: state([session("a", .needsResponse, wait: .question)]),
                                    now: now) == [.needsAnswer])
        #expect(transitions.advance(to: state([session("a", .working)]), now: now).isEmpty)
        #expect(transitions.advance(to: state([session("a", .needsResponse, wait: .question)]),
                                    now: now) == [.needsAnswer])
    }

    @Test("a wait that changes kind on the same session speaks again")
    func waitKindChange() {
        var transitions = WatchHapticTransitions()
        let now = Date(timeIntervalSince1970: 100)
        _ = transitions.advance(to: state([session("a", .working)]), now: now)
        #expect(transitions.advance(to: state([session("a", .needsResponse, wait: .question)]),
                                    now: now) == [.needsAnswer])
        #expect(transitions.advance(to: state([session("a", .needsResponse, wait: .permission)]),
                                    now: now) == [.needsApproval])
    }

    @Test("a followed session finishing or failing earns its own cue")
    func completionAndFailure() {
        var transitions = WatchHapticTransitions()
        let now = Date(timeIntervalSince1970: 100)
        _ = transitions.advance(to: state([session("a", .working), session("b", .working)]), now: now)

        let done = state([session("a", .done, unread: true), session("b", .working)])
        #expect(transitions.advance(to: done, now: now) == [.agentDone])

        let failed = state([session("a", .done, unread: true),
                            session("b", .done, failed: true)])
        #expect(transitions.advance(to: failed, now: now) == [.agentStuck])
        #expect(transitions.advance(to: failed, now: now).isEmpty)
    }

    @Test("one snapshot says one thing, and a wait outranks the rest")
    func onePerSnapshot() {
        var transitions = WatchHapticTransitions()
        let now = Date(timeIntervalSince1970: 100)
        _ = transitions.advance(to: state([session("a", .working), session("b", .working)]), now: now)
        let both = state([session("a", .needsResponse, wait: .permission),
                          session("b", .done, failed: true)])
        // Both boundaries are reported, most urgent first, so the caller can
        // fall through to the second one if the first is muted...
        let earned = transitions.advance(to: both, now: now)
        #expect(earned == [.needsApproval, .agentStuck])
        // ...but only one of them is ever said.
        #expect(WatchHaptics.cue(forAnyOf: earned, categories: allOn, quiet: false)?.category
                == .needsApproval)
        // The failure it did not announce is still recorded, so it is not
        // replayed as news on the next snapshot.
        #expect(transitions.advance(to: both, now: now).isEmpty)
    }

    @Test("a different Mac or a re-pairing is a new world, not a transition")
    func sourceChange() {
        var transitions = WatchHapticTransitions()
        let now = Date(timeIntervalSince1970: 100)
        _ = transitions.advance(to: state([session("a", .working)]), now: now)

        var other = state([session("a", .needsResponse, wait: .permission)])
        other.sourceID = "mac-b"
        #expect(transitions.advance(to: other, now: now).isEmpty)
        // ...and the new world's own transitions work from there.
        var otherWorking = state([session("a", .working)])
        otherWorking.sourceID = "mac-b"
        #expect(transitions.advance(to: otherWorking, now: now).isEmpty)
        #expect(transitions.advance(to: other, now: now) == [.needsApproval])
    }

    // MARK: Quota

    @Test("an allowance crossing into nearly-spent speaks once")
    func quotaCrossing() {
        var transitions = WatchHapticTransitions()
        let now = Date(timeIntervalSince1970: 100)
        _ = transitions.advance(to: state([], quotas: [quota(.codex, remaining: 40)]), now: now)

        let low = state([], quotas: [quota(.codex, remaining: WatchHaptics.lowQuotaPercent)])
        #expect(transitions.advance(to: low, now: now) == [.quota])
        #expect(transitions.advance(to: low, now: now).isEmpty)

        // Refilled, then spent again: a second window, a second cue.
        _ = transitions.advance(to: state([], quotas: [quota(.codex, remaining: 80)]), now: now)
        #expect(transitions.advance(to: low, now: now) == [.quota])
    }

    @Test("a reading that says nothing leaves the verdict standing")
    func quotaWithoutEvidence() {
        var transitions = WatchHapticTransitions()
        let now = Date(timeIntervalSince1970: 100)
        _ = transitions.advance(to: state([], quotas: [quota(.codex, remaining: 40)]), now: now)
        #expect(transitions.advance(to: state([], quotas: [quota(.codex, remaining: 3)]),
                                    now: now) == [.quota])
        // Source goes quiet, then reports the same exhausted window again.
        let blank = state([], quotas: [.unavailable(.codex, reason: "signed out")])
        #expect(transitions.advance(to: blank, now: now).isEmpty)
        #expect(transitions.advance(to: state([], quotas: [quota(.codex, remaining: 3)]),
                                    now: now).isEmpty)
    }

    @Test("a stale reading is not evidence that an allowance just ran out")
    func staleQuota() {
        var transitions = WatchHapticTransitions()
        let now = Date(timeIntervalSince1970: 100)
        _ = transitions.advance(to: state([], quotas: [quota(.codex, remaining: 40)]), now: now)
        let old = quota(.codex, remaining: 2, now: 100 - ProviderQuota.staleAfter - 60)
        #expect(transitions.advance(to: state([], quotas: [old]), now: now).isEmpty)
    }

    @Test("a wait outranks an allowance arriving in the same snapshot")
    func quotaRanksLast() {
        var transitions = WatchHapticTransitions()
        let now = Date(timeIntervalSince1970: 100)
        _ = transitions.advance(to: state([session("a", .working)],
                                          quotas: [quota(.codex, remaining: 40)]), now: now)
        let both = state([session("a", .needsResponse, wait: .question)],
                         quotas: [quota(.codex, remaining: 4)])
        let earned = transitions.advance(to: both, now: now)
        #expect(earned == [.needsAnswer, .quota])
        #expect(WatchHaptics.cue(forAnyOf: earned, categories: allOn, quiet: false)?.category
                == .needsAnswer)
        #expect(transitions.advance(to: both, now: now).isEmpty)
    }

    // MARK: Choosing under the mute rules

    @Test("a muted cue does not use up the snapshot's one turn to speak")
    func mutedCueYieldsToTheNextOne() {
        // Quiet silences the completion; the allowance warning that arrived with
        // it answers only to its own switch and must still be felt.
        let cue = WatchHaptics.cue(forAnyOf: [.agentDone, .quota], categories: allOn, quiet: true)
        #expect(cue?.category == .quota)
        #expect(cue?.beats == [.short, .long])

        // Same shape with a switch rather than Quiet.
        var completionOff = allOn
        completionOff.set(NotificationSound.agentDone, enabled: false)
        let next = WatchHaptics.cue(forAnyOf: [.agentDone, .quota],
                                    categories: completionOff, quiet: false)
        #expect(next?.category == .quota)
    }

    @Test("the most urgent audible cue wins, and all-muted is silence")
    func cueSelection() {
        let loud = WatchHaptics.cue(forAnyOf: [.quota, .agentStuck, .needsApproval],
                                    categories: allOn, quiet: false)
        #expect(loud?.category == .needsApproval)
        #expect(loud?.beats == [.long, .long, .long, .long, .long])

        var nothing = allOn
        nothing.quota = false
        nothing.enabled = []
        #expect(WatchHaptics.cue(forAnyOf: [.needsApproval, .agentDone, .quota],
                                 categories: nothing, quiet: false) == nil)
        #expect(WatchHaptics.cue(forAnyOf: [], categories: allOn, quiet: false) == nil)
    }

    @Test("a snapshot that carries no quota at all keeps the standing verdict")
    func quotaAbsentFromSnapshot() {
        // The Mac's `providerQuota` is optional on the wire, so the iPhone can
        // relay an empty list under the same Mac and pairing. That is silence,
        // not evidence that the allowance refilled.
        var transitions = WatchHapticTransitions()
        let now = Date(timeIntervalSince1970: 100)
        _ = transitions.advance(to: state([], quotas: [quota(.codex, remaining: 40)]), now: now)
        #expect(transitions.advance(to: state([], quotas: [quota(.codex, remaining: 6)]),
                                    now: now) == [.quota])
        #expect(transitions.advance(to: state([], quotas: []), now: now).isEmpty)
        #expect(transitions.advance(to: state([], quotas: [quota(.codex, remaining: 6)]),
                                    now: now).isEmpty)
    }

    @Test("a re-pairing starts the allowance verdict over with everything else")
    func quotaResetsWithTheWorld() {
        var transitions = WatchHapticTransitions()
        let now = Date(timeIntervalSince1970: 100)
        _ = transitions.advance(to: state([], quotas: [quota(.codex, remaining: 40)]), now: now)
        #expect(transitions.advance(to: state([], quotas: [quota(.codex, remaining: 6)]),
                                    now: now) == [.quota])

        // A new pairing: whatever it opens with is that world's baseline, and
        // the world's own crossings work from there.
        var fresh = state([], quotas: [quota(.codex, remaining: 40)])
        fresh.pairingEpoch = "epoch-2"
        #expect(transitions.advance(to: fresh, now: now).isEmpty)
        var spent = state([], quotas: [quota(.codex, remaining: 6)])
        spent.pairingEpoch = "epoch-2"
        #expect(transitions.advance(to: spent, now: now) == [.quota])
    }
}
