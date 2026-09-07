import Testing
import Foundation
@testable import VibeBuddyKit

/// The sound pack's *sounding rules* live here, as pure logic over snapshot
/// transitions: which state boundary earns a sound, and which "process noise"
/// stays silent. Mirrors the spec — only boundaries ring, never every refresh.
@Suite("SoundPolicy")
struct SoundPolicyTests {

    private func session(_ id: String, _ status: SessionStatus,
                         wait: WaitKind? = nil,
                         since: TimeInterval = 0,
                         summary: String? = nil,
                         probeRetired: Bool? = nil,
                         attention: SessionAttention? = nil) -> AgentSession {
        AgentSession(id: id, agent: .claudeCode, project: id, status: status,
                     waitKind: wait, summary: summary, probeRetired: probeRetired,
                     attention: attention,
                     statusSince: Date(timeIntervalSince1970: since),
                     updatedAt: Date(timeIntervalSince1970: since))
    }

    private func input(_ sessions: [AgentSession], now: TimeInterval,
                       appActive: Bool = false, quiet: Bool = false,
                       focused: Set<String> = []) -> SoundPolicyInput {
        SoundPolicyInput(sessions: sessions, now: Date(timeIntervalSince1970: now),
                         appActive: appActive, quietMode: quiet, focusedSessionIDs: focused)
    }

    // MARK: NotificationSound

    @Test("a sound names its bundled .caf file")
    func fileName() {
        #expect(NotificationSound.needsApproval.fileName == "needs_approval.caf")
        #expect(NotificationSound.agentDone.fileName == "agent_done.caf")
    }

    // MARK: DeliveryMatrix — the one table

    @Test("the matrix matches the spec table row by row")
    func matrixTable() {
        typealias Row = (NotificationSound, DeliveryLevel, DeliveryLevel, DeliveryLevel)
        let rows: [Row] = [
            (.needsApproval, .bannerSound, .bannerSound, .banner),
            (.needsAnswer,   .bannerSound, .bannerSound, .banner),
            (.agentStuck,    .bannerSound, .banner,      .list),
            (.agentDone,     .banner,      .banner,      .drop),
            (.longWaitNudge, .banner,      .list,        .drop),
        ]
        for (sound, followed, normal, muted) in rows {
            #expect(DeliveryMatrix.level(for: sound, attention: .followed) == followed, "\(sound) followed")
            #expect(DeliveryMatrix.level(for: sound, attention: .normal) == normal, "\(sound) normal")
            #expect(DeliveryMatrix.level(for: sound, attention: .muted) == muted, "\(sound) muted")
        }
    }

    @Test("delivery levels order silent → loud, and only banners interrupt")
    func deliveryOrdering() {
        #expect(DeliveryLevel.drop < .list && .list < .banner && .banner < .bannerSound)
        #expect(!DeliveryLevel.list.interrupts && DeliveryLevel.banner.interrupts)
        #expect(DeliveryLevel.bannerSound.makesSound && !DeliveryLevel.banner.makesSound)
    }

    @Test("Time Sensitive is bannerSound × approval/question, never muted")
    func timeSensitiveOnlyForLoudWaits() {
        let waiting = session("a", .needsResponse, wait: .permission)
        #expect(SoundAlert(session: waiting, sound: .needsApproval, delivery: .bannerSound).isTimeSensitive)
        #expect(SoundAlert(session: waiting, sound: .needsAnswer, delivery: .bannerSound).isTimeSensitive)
        #expect(!SoundAlert(session: waiting, sound: .needsApproval, delivery: .banner).isTimeSensitive)
        #expect(!SoundAlert(session: waiting, sound: .needsAnswer, delivery: .list).isTimeSensitive)
        #expect(!SoundAlert(session: waiting, sound: .agentDone, delivery: .bannerSound).isTimeSensitive)
        #expect(!SoundAlert(session: waiting, sound: .agentStuck, delivery: .bannerSound).isTimeSensitive)
    }

    @Test("shared category and action ids cover approval and question only")
    func notificationCategoryIDs() {
        #expect(NotificationCategoryID.forSound(.needsApproval) == .approval)
        #expect(NotificationCategoryID.forSound(.needsAnswer) == .question)
        #expect(NotificationCategoryID.forSound(.agentDone) == nil)
        #expect(NotificationCategoryID.approval.rawValue == "approval")
        #expect(NotificationCategoryID.question.rawValue == "question")
        #expect(NotificationActionID.approve.rawValue == "approve")
        #expect(NotificationActionID.deny.rawValue == "deny")
        #expect(NotificationActionID.answer.rawValue == "answer")
        #expect(WaitActionResult(statusCode: 200) == .accepted)
        #expect(WaitActionResult(statusCode: 404) == .alreadyResolved)
        #expect(WaitActionResult(statusCode: 409) == .alreadyResolved)
        #expect(WaitActionResult(statusCode: 500) == .failed)
        #expect(WaitActionResult(statusCode: 404).shouldOpenSession)
        #expect(!WaitActionResult(statusCode: 200).shouldOpenSession)
        #expect(NotificationUserInfoKey.make(sessionId: "s", approvalId: "ap")
            == [NotificationUserInfoKey.sessionId: "s", NotificationUserInfoKey.approvalId: "ap"])
    }

    @Test("read-only native waits have no banner actions on any surface")
    func readOnlyWaitsHaveNoActions() {
        var waiting = session("a", .needsResponse, wait: .permission)
        waiting.pendingApproval = PendingApproval(id: "p", tool: "Bash", commandPreview: "pwd")
        #expect(SoundAlert(session: waiting, sound: .needsApproval).actionCategory == .approval)
        waiting.pendingApproval = PendingApproval(id: "p", tool: "Bash", commandPreview: "pwd", answerable: false)
        #expect(SoundAlert(session: waiting, sound: .needsApproval).actionCategory == nil)
        waiting.pendingQuestion = PendingQuestion(id: "q", prompt: "Continue?", answerable: false)
        #expect(SoundAlert(session: waiting, sound: .needsAnswer).actionCategory == nil)
        waiting.pendingQuestion = PendingQuestion(id: "q", prompt: "Continue?", answerable: true)
        #expect(SoundAlert(session: waiting, sound: .needsAnswer).actionCategory == .question)
    }

    // MARK: First snapshot — no backlog noise

    @Test("the first snapshot's already-waiting sessions stay silent")
    func firstSnapshotSilent() {
        let p = SoundPolicy()
        let alerts = p.evaluate(input([session("a", .needsResponse, wait: .question)], now: 0))
        #expect(alerts.isEmpty)
    }

    // MARK: needsResponse — answer / approval, fired once

    @Test("a fresh question transition rings needs_answer")
    func freshQuestion() {
        let p = SoundPolicy()
        _ = p.evaluate(input([session("a", .working)], now: 0))
        let alerts = p.evaluate(input([session("a", .needsResponse, wait: .question, since: 1)], now: 1))
        #expect(alerts.map(\.sound) == [.needsAnswer])
        #expect(alerts.map(\.delivery) == [.bannerSound])   // a question blocks you: loud even at normal attention
    }

    @Test("a fresh permission transition rings needs_approval")
    func freshPermission() {
        let p = SoundPolicy()
        _ = p.evaluate(input([session("a", .working)], now: 0))
        let alerts = p.evaluate(input([session("a", .needsResponse, wait: .permission, since: 1)], now: 1))
        #expect(alerts.map(\.sound) == [.needsApproval])
        #expect(alerts.map(\.delivery) == [.bannerSound])
    }

    // MARK: attention — the matrix applied per session

    @Test("a followed session's question rings out loud")
    func followedQuestionLoud() {
        let p = SoundPolicy()
        _ = p.evaluate(input([session("a", .working)], now: 0))
        let alerts = p.evaluate(input([session("a", .needsResponse, wait: .question, since: 1,
                                               attention: .followed)], now: 1))
        #expect(alerts.map(\.delivery) == [.bannerSound])
    }

    @Test("a muted session's approval still shows, silently")
    func mutedApprovalSilentBanner() {
        let p = SoundPolicy()
        _ = p.evaluate(input([session("a", .working)], now: 0))
        let alerts = p.evaluate(input([session("a", .needsResponse, wait: .permission, since: 1,
                                               attention: .muted)], now: 1))
        #expect(alerts.map(\.delivery) == [.banner])
    }

    @Test("a muted session's completion is dropped — not even in the list")
    func mutedDoneDropped() {
        let p = SoundPolicy()
        _ = p.evaluate(input([session("a", .working, since: 0)], now: 0))
        let alerts = p.evaluate(input([session("a", .done, since: 40, attention: .muted)],
                                      now: 40, appActive: false))
        #expect(alerts.isEmpty)
    }

    @Test("a completion banners silently for normal and followed sessions, and is dropped for a muted one")
    func doneByAttention() {
        let p = SoundPolicy()
        _ = p.evaluate(input([session("a", .working, since: 0), session("b", .working, since: 0),
                              session("c", .working, since: 0)], now: 0))
        let alerts = p.evaluate(input([session("a", .done, since: 40),
                                       session("b", .done, since: 40, attention: .followed),
                                       session("c", .done, since: 40, attention: .muted)],
                                      now: 40, appActive: false))
        #expect(alerts.map { "\($0.sessionID):\($0.delivery)" } == ["a:banner", "b:banner"])
    }

    @Test("a session that keeps waiting does not re-ring")
    func noRefireWhileWaiting() {
        let p = SoundPolicy()
        _ = p.evaluate(input([session("a", .working)], now: 0))
        _ = p.evaluate(input([session("a", .needsResponse, wait: .question, since: 1)], now: 1))
        let again = p.evaluate(input([session("a", .needsResponse, wait: .question, since: 1)], now: 3))
        #expect(again.isEmpty)
    }

    // MARK: 90s per-session debounce on re-entry

    @Test("re-entering needsResponse within 90s is debounced")
    func debouncedReentry() {
        let p = SoundPolicy()
        _ = p.evaluate(input([session("a", .working)], now: 0))
        _ = p.evaluate(input([session("a", .needsResponse, wait: .question, since: 1)], now: 1))   // ring
        _ = p.evaluate(input([session("a", .working, since: 10)], now: 10))                         // left
        let re = p.evaluate(input([session("a", .needsResponse, wait: .question, since: 20)], now: 20)) // 19s later
        #expect(re.isEmpty)
    }

    @Test("re-entering needsResponse after 90s rings again")
    func reentryAfterDebounce() {
        let p = SoundPolicy()
        _ = p.evaluate(input([session("a", .working)], now: 0))
        _ = p.evaluate(input([session("a", .needsResponse, wait: .question, since: 1)], now: 1))   // ring at 1
        _ = p.evaluate(input([session("a", .working, since: 10)], now: 10))                         // left
        let re = p.evaluate(input([session("a", .needsResponse, wait: .question, since: 100)], now: 100))
        #expect(re.map(\.sound) == [.needsAnswer])
    }

    // MARK: done — only when it actually ran, and you're not watching

    @Test("an abandoned writer does not ring agent_done")
    func abandonedDoneSilent() {
        let p = SoundPolicy()
        _ = p.evaluate(input([session("a", .working, since: 0)], now: 0))
        let alerts = p.evaluate(input([session("a", .done, since: 40, summary: "Abandoned",
                                               probeRetired: true)],
                                      now: 40, appActive: false))
        #expect(alerts.isEmpty)
    }

    @Test("done after a >30s run while the app is backgrounded rings agent_done")
    func doneBackgrounded() {
        let p = SoundPolicy()
        _ = p.evaluate(input([session("a", .working, since: 0)], now: 0))
        let alerts = p.evaluate(input([session("a", .done, since: 40)], now: 40, appActive: false))
        #expect(alerts.map(\.sound) == [.agentDone])
    }

    @Test("done is silent while you are looking at the app")
    func doneForegroundSilent() {
        let p = SoundPolicy()
        _ = p.evaluate(input([session("a", .working, since: 0)], now: 0))
        let alerts = p.evaluate(input([session("a", .done, since: 40)], now: 40, appActive: true))
        #expect(alerts.isEmpty)
    }

    @Test("a focused terminal caps its own session to the list — even a followed approval")
    func focusedTerminalCapsToList() {
        let p = SoundPolicy()
        _ = p.evaluate(input([session("a", .working, since: 0), session("b", .working, since: 0)], now: 0))
        let alerts = p.evaluate(input([session("a", .done, since: 40, attention: .followed),
                                       session("b", .needsResponse, wait: .permission, since: 40,
                                               attention: .followed)],
                                      now: 40, appActive: false, focused: ["a", "b"]))
        #expect(alerts.map { "\($0.sound.rawValue):\($0.delivery)" } == ["agent_done:list", "needs_approval:list"])
    }

    @Test("leaving presence restores a still-open wait at full matrix level")
    func leavingPresenceRestoresWait() {
        let p = SoundPolicy()
        let waiting = session("a", .needsResponse, wait: .permission, since: 1)
        _ = p.evaluate(input([session("a", .working)], now: 0))
        let present = p.evaluate(input([waiting], now: 1, focused: ["a"]))
        #expect(present.map(\.delivery) == [.list])
        let away = p.evaluate(input([waiting], now: 3, focused: []))
        #expect(away.map(\.sound) == [.needsApproval])
        #expect(away.map(\.delivery) == [.bannerSound])
    }

    @Test("an answered wait is not replayed after leaving presence")
    func leavingPresenceDoesNotReplayHandledWait() {
        let p = SoundPolicy()
        _ = p.evaluate(input([session("a", .working)], now: 0))
        _ = p.evaluate(input([session("a", .needsResponse, wait: .question, since: 1)], now: 1, focused: ["a"]))
        _ = p.evaluate(input([session("a", .working, since: 2)], now: 2, focused: ["a"]))
        let away = p.evaluate(input([session("a", .working, since: 2)], now: 3, focused: []))
        #expect(away.isEmpty)
    }

    @Test("leaving presence a second time does not re-ring the same wait")
    func leavingPresenceRestoresOnce() {
        let p = SoundPolicy()
        let waiting = session("a", .needsResponse, wait: .question, since: 1)
        _ = p.evaluate(input([session("a", .working)], now: 0))
        _ = p.evaluate(input([waiting], now: 1, focused: ["a"]))
        _ = p.evaluate(input([waiting], now: 3, focused: []))
        _ = p.evaluate(input([waiting], now: 4, focused: ["a"]))
        let again = p.evaluate(input([waiting], now: 5, focused: []))
        #expect(again.isEmpty)
    }

    @Test("Quiet mode still caps a restored wait — presence never outranks Focus")
    func leavingPresenceRespectsQuiet() {
        let p = SoundPolicy()
        let waiting = session("a", .needsResponse, wait: .permission, since: 1)
        _ = p.evaluate(input([session("a", .working)], now: 0))
        _ = p.evaluate(input([waiting], now: 1, focused: ["a"]))
        let away = p.evaluate(input([waiting], now: 3, quiet: true, focused: []))
        #expect(away.map(\.sound) == [.needsApproval])
        #expect(away.map(\.delivery) == [.banner])
    }

    @Test("a wait first seen while present still restores after leaving — the arrival verdict does not freeze")
    func firstSnapshotPresentThenLeaveRestores() {
        let p = SoundPolicy()
        let waiting = session("a", .needsResponse, wait: .permission, since: 0)
        #expect(p.evaluate(input([waiting], now: 0, focused: ["a"])).isEmpty)
        let away = p.evaluate(input([waiting], now: 2, focused: []))
        #expect(away.map(\.sound) == [.needsApproval])
        #expect(away.map(\.delivery) == [.bannerSound])
    }

    @Test("done still rings for a session whose terminal is NOT the focused one")
    func doneOtherTerminalRings() {
        let p = SoundPolicy()
        _ = p.evaluate(input([session("a", .working, since: 0)], now: 0))
        // The user is staring at session "b"'s terminal; "a" finishing should still ring.
        let alerts = p.evaluate(input([session("a", .done, since: 40)], now: 40,
                                      appActive: false, focused: ["b"]))
        #expect(alerts.map(\.sound) == [.agentDone])
    }

    @Test("done after a <30s run stays silent — too quick to be worth a sound")
    func doneShortRunSilent() {
        let p = SoundPolicy()
        _ = p.evaluate(input([session("a", .working, since: 0)], now: 0))
        let alerts = p.evaluate(input([session("a", .done, since: 20)], now: 20, appActive: false))
        #expect(alerts.isEmpty)
    }

    @Test("a session first seen already done never rings completion")
    func unknownDoneSilent() {
        let p = SoundPolicy()
        _ = p.evaluate(input([session("a", .working)], now: 0))   // first snapshot, a known
        let alerts = p.evaluate(input([session("a", .working),
                                       session("b", .done, since: 40)], now: 40, appActive: false))
        #expect(alerts.isEmpty)   // b appeared out of nowhere as done
    }

    // MARK: stuck heuristic — a failed/aborted ending sounds duller

    @Test("done with a failure summary rings agent_stuck instead of agent_done")
    func failureRingsStuck() {
        let p = SoundPolicy()
        _ = p.evaluate(input([session("a", .working, since: 0)], now: 0))
        let alerts = p.evaluate(input([session("a", .done, since: 40, summary: "Build failed: 3 errors")],
                                      now: 40, appActive: false))
        #expect(alerts.map(\.sound) == [.agentStuck])
    }

    @Test("the real failed flag rings stuck even with a benign summary")
    func failedFlagRingsStuck() {
        let p = SoundPolicy()
        _ = p.evaluate(input([session("a", .working, since: 0)], now: 0))
        var done = session("a", .done, since: 40, summary: "All changes applied cleanly")
        done.failed = true
        let alerts = p.evaluate(input([done], now: 40, appActive: false))
        #expect(alerts.map(\.sound) == [.agentStuck])
    }

    @Test("a quick failure still rings stuck — failures matter regardless of runtime")
    func quickFailureRingsStuck() {
        let p = SoundPolicy()
        _ = p.evaluate(input([session("a", .working, since: 0)], now: 0))
        let alerts = p.evaluate(input([session("a", .done, since: 5, summary: "fatal error: process crashed")],
                                      now: 5, appActive: false))
        #expect(alerts.map(\.sound) == [.agentStuck])
    }

    @Test("a failed ending is silent while you are watching")
    func failureForegroundSilent() {
        let p = SoundPolicy()
        _ = p.evaluate(input([session("a", .working, since: 0)], now: 0))
        let alerts = p.evaluate(input([session("a", .done, since: 40, summary: "Tests failed")],
                                      now: 40, appActive: true))
        #expect(alerts.isEmpty)
    }

    // MARK: Quiet / Focus mode — every session reads as muted

    @Test("Quiet mode still shows a question, silently, even for a followed session")
    func quietQuestionSilentBanner() {
        let p = SoundPolicy()
        _ = p.evaluate(input([session("a", .working)], now: 0))
        let alerts = p.evaluate(input([session("a", .needsResponse, wait: .question, since: 1,
                                               attention: .followed)],
                                      now: 1, quiet: true))
        #expect(alerts.map(\.delivery) == [.banner])
    }

    @Test("Quiet mode still shows an approval, without its sound")
    func quietKeepsApprovalSilently() {
        let p = SoundPolicy()
        _ = p.evaluate(input([session("a", .working)], now: 0))
        let alerts = p.evaluate(input([session("a", .needsResponse, wait: .permission, since: 1)],
                                      now: 1, quiet: true))
        #expect(alerts.map(\.sound) == [.needsApproval])
        #expect(alerts.map(\.delivery) == [.banner])
    }

    @Test("Quiet mode drops completion")
    func quietDropsDone() {
        let p = SoundPolicy()
        _ = p.evaluate(input([session("a", .working, since: 0)], now: 0))
        let alerts = p.evaluate(input([session("a", .done, since: 40)], now: 40,
                                      appActive: false, quiet: true))
        #expect(alerts.isEmpty)
    }

    // MARK: long-wait nudge — one gentle reminder after the threshold

    @Test("a wait past the threshold earns one long_wait_nudge")
    func longWaitNudges() {
        let p = SoundPolicy()
        _ = p.evaluate(input([session("a", .working)], now: 0))
        _ = p.evaluate(input([session("a", .needsResponse, wait: .question, since: 1)], now: 1))  // initial ping
        let nudge = p.evaluate(input([session("a", .needsResponse, wait: .question, since: 1)], now: 200))
        #expect(nudge.map(\.sound) == [.longWaitNudge])
        #expect(nudge.map(\.delivery) == [.list])   // normal attention: a nudge never interrupts
    }

    @Test("the long-wait nudge fires only once per wait")
    func longWaitOnce() {
        let p = SoundPolicy()
        _ = p.evaluate(input([session("a", .working)], now: 0))
        _ = p.evaluate(input([session("a", .needsResponse, wait: .question, since: 1)], now: 1))
        _ = p.evaluate(input([session("a", .needsResponse, wait: .question, since: 1)], now: 200))  // nudge
        let again = p.evaluate(input([session("a", .needsResponse, wait: .question, since: 1)], now: 260))
        #expect(again.isEmpty)
    }

    @Test("Quiet mode drops the long-wait nudge")
    func quietDropsLongWait() {
        let p = SoundPolicy()
        _ = p.evaluate(input([session("a", .working)], now: 0))
        _ = p.evaluate(input([session("a", .needsResponse, wait: .question, since: 1)], now: 1))
        let nudge = p.evaluate(input([session("a", .needsResponse, wait: .question, since: 1)],
                                     now: 200, quiet: true))
        #expect(nudge.isEmpty)
    }
}
