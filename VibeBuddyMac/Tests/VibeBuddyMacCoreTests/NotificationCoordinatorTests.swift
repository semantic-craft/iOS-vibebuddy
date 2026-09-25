import Testing
import Foundation
import VibeBuddyKit
@testable import VibeBuddyMacCore

/// The coordinator is a thin adapter over `SoundPolicy` (whose full rule matrix
/// is tested in VibeBuddyKit). These tests pin the adapter's contract: it
/// forwards the policy's cues to the notifier, stays silent on the opening
/// backlog, threads Quiet mode through, and records delivery *after* the
/// existing policy decision — never claiming delivered.
@Suite("NotificationCoordinator — forwards SoundPolicy cues")
struct NotificationCoordinatorTests {

    /// Records the sounds it was asked to play, paired with the session id.
    final class SpyNotifier: AttentionNotifier {
        var result: LocalNotificationAttempt = .scheduled()
        private(set) var played: [(id: String, sound: NotificationSound)] = []
        private(set) var levels: [DeliveryLevel] = []
        private(set) var withdrawn: [[String]] = []
        func notify(_ alert: SoundAlert) async -> LocalNotificationAttempt {
            played.append((alert.sessionID, alert.sound))
            levels.append(alert.delivery)
            return result
        }
        func withdraw(_ identifiers: [String]) async { withdrawn.append(identifiers) }
    }

    private func session(_ id: String, _ status: SessionStatus, wait: WaitKind? = nil,
                         agent: AgentKind = .claudeCode,
                         since: Date = Date(timeIntervalSince1970: 0)) -> AgentSession {
        AgentSession(id: id, agent: agent, project: "p",
                     status: status, waitKind: wait, statusSince: since, updatedAt: since)
    }

    final class EligibleSpeechSpy: @unchecked Sendable {
        private let lock = NSLock()
        private var sessions: [String] = []
        func record(_ alert: SoundAlert) { lock.withLock { sessions.append(alert.sessionID) } }
        var ids: [String] { lock.withLock { sessions } }
    }

    @Test("Short new completion speaks once without a cue or a sampled Working state")
    func shortCompletionSpeech() async {
        let spy = SpyNotifier(), speech = EligibleSpeechSpy()
        let coordinator = NotificationCoordinator(notifier: spy, onEligible: { speech.record($0) })
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        await coordinator.observe([], now: now, appActive: false, quietMode: false)
        var done = session("short", .done, since: now.addingTimeInterval(2))
        done.completionID = "round-1"; done.hasUnreadCompletion = true
        await coordinator.observe([done], now: now.addingTimeInterval(2), appActive: false, quietMode: false)
        done.hasUnreadCompletion = false
        await coordinator.observe([done], now: now.addingTimeInterval(3), appActive: false, quietMode: false)
        done.hasUnreadCompletion = true
        await coordinator.observe([done], now: now.addingTimeInterval(4), appActive: false, quietMode: false)
        #expect(speech.ids == ["short"])
        #expect(spy.played.isEmpty)
        done.completionID = "round-2"; done.statusSince = now.addingTimeInterval(5)
        await coordinator.observe([done], now: now.addingTimeInterval(5), appActive: false, quietMode: true)
        await coordinator.observe([done], now: now.addingTimeInterval(6), appActive: false, quietMode: false)
        #expect(speech.ids == ["short"])
        done.completionID = "round-3"; done.statusSince = now.addingTimeInterval(7)
        done.completionNotice = CompletionNotice(id: "notice-3", deadline: now.addingTimeInterval(10))
        await coordinator.observe([done], now: now.addingTimeInterval(7), appActive: true, quietMode: false)
        done.hasUnreadCompletion = false
        done.completionNotice?.state = .cancelled
        await coordinator.observe([done], now: now.addingTimeInterval(8), appActive: true, quietMode: false)
        #expect(speech.ids == ["short", "short"])
    }

    @Test("Only the viewed completion is quiet; another task and a real question still notify")
    func completionViewingIsPerTaskAndPerChannel() async {
        let spy = SpyNotifier()
        let speech = EligibleSpeechSpy()
        let coordinator = NotificationCoordinator(notifier: spy, onEligible: { speech.record($0) })
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        await coordinator.observe([session("viewed", .working, since: now),
                                   session("other", .working, since: now),
                                   session("question", .working, since: now)],
                                  now: now, appActive: true, quietMode: false)
        await coordinator.observe([session("viewed", .done, since: now),
                                   session("other", .done, since: now),
                                   session("question", .needsResponse, wait: .question, since: now)],
                                  now: now.addingTimeInterval(60), appActive: true, quietMode: false,
                                  viewedSessionIDs: ["viewed", "question"])
        let levels = Dictionary(uniqueKeysWithValues: zip(spy.played.map(\.id), spy.levels))
        #expect(Set(speech.ids) == ["viewed", "other", "question"])
        #expect(levels["viewed"] == .list)
        #expect(levels["other"] == .banner)
        #expect(levels["question"] == .bannerSound)
    }

    @Test("App-level presence cannot silence an unviewed followed Codex completion")
    func appPresenceDoesNotSuppressSiblingPush() async {
        let coordinator = NotificationCoordinator(notifier: SpyNotifier())
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var viewed = session("viewed", .working, agent: .codex, since: now)
        var other = session("other", .working, agent: .codex, since: now)
        viewed.attention = .followed
        other.attention = .followed
        await coordinator.observe([viewed, other], now: now, appActive: true, quietMode: false)
        viewed.status = .done
        other.status = .done
        let alerts = await coordinator.observe([viewed, other], now: now.addingTimeInterval(60),
            appActive: true, quietMode: false,
            focusedSessionIDs: ["viewed", "other"], viewedSessionIDs: ["viewed"])
        #expect(alerts.first { $0.sessionID == "viewed" }?.delivery == .list)
        #expect(alerts.first { $0.sessionID == "other" }?.delivery == .bannerSound)
    }

    @Test("Claude and Codex transitions share the notification pipeline")
    func bothAgentsNotify() async {
        let spy = SpyNotifier()
        let c = NotificationCoordinator(notifier: spy)
        await c.observe([session("claude", .working),
                         session("codex", .working, agent: .codex)],
                        appActive: false, quietMode: false)
        await c.observe([session("claude", .needsResponse, wait: .permission),
                         session("codex", .done, agent: .codex)],
                        appActive: false, quietMode: false)
        #expect(Set(spy.played.map { "\($0.id):\($0.sound.rawValue)" }) == [
            "claude:needs_approval", "codex:agent_done",
        ])
    }

    @Test("a category the Mac turned off is never forwarded; Quiet mode keeps what blocks you, silently")
    func categoriesFilterBeforePosting() async {
        let spy = SpyNotifier()
        let c = NotificationCoordinator(notifier: spy)
        var prefs = NotificationCategoryPrefs.default
        prefs.set(NotificationSound.agentDone, enabled: false)
        let t0 = Date(timeIntervalSince1970: 0)
        await c.observe([session("done", .working, since: t0),
                         session("ask", .working, since: t0),
                         session("ok", .working, since: t0)],
                        now: t0, appActive: false, quietMode: false, categories: prefs)
        await c.observe([session("done", .done, since: t0.addingTimeInterval(60)),
                         session("ask", .needsResponse, wait: .question, since: t0.addingTimeInterval(60)),
                         session("ok", .needsResponse, wait: .permission, since: t0.addingTimeInterval(60))],
                        now: t0.addingTimeInterval(60), appActive: false, quietMode: false, categories: prefs)
        #expect(Set(spy.played.map { "\($0.id):\($0.sound.rawValue)" }) == [
            "ask:needs_answer", "ok:needs_approval",
        ])

        // Quiet mode on top of the categories: every session reads as muted, so
        // the approval and the question still show (silent banners) and a
        // completion is dropped.
        let quietSpy = SpyNotifier()
        let q = NotificationCoordinator(notifier: quietSpy)
        var allOn = NotificationCategoryPrefs.default
        allOn.set(NotificationSound.agentDone, enabled: true)
        await q.observe([session("ask", .working, since: t0), session("ok", .working, since: t0),
                         session("fin", .working, since: t0)],
                        now: t0, appActive: false, quietMode: true, categories: allOn)
        let quiet = await q.observe([session("ask", .needsResponse, wait: .question, since: t0.addingTimeInterval(60)),
                                     session("ok", .needsResponse, wait: .permission, since: t0.addingTimeInterval(60)),
                                     session("fin", .done, since: t0.addingTimeInterval(60))],
                                    now: t0.addingTimeInterval(60), appActive: false, quietMode: true, categories: allOn)
        #expect(quietSpy.played.map(\.id) == ["ask", "ok"])
        #expect(quiet.map(\.delivery) == [.banner, .banner])
    }

    @Test("a category the Mac turned off leaves a skipped record, not an absence")
    func macSwitchesRecordWhyTheyWereSilent() async {
        let spy = SpyNotifier()
        let delivery = SpyDelivery()
        let c = NotificationCoordinator(notifier: spy, delivery: delivery)
        var prefs = NotificationCategoryPrefs.default
        prefs.set(NotificationSound.agentDone, enabled: false)
        let t0 = Date(timeIntervalSince1970: 0)
        _ = await c.observe([session("done", .working, since: t0)], now: t0,
                            appActive: false, quietMode: false, categories: prefs)
        _ = await c.observe([session("done", .done, since: t0.addingTimeInterval(60))],
                            now: t0.addingTimeInterval(60),
                            appActive: false, quietMode: false, categories: prefs)
        #expect(spy.played.isEmpty)   // the switch is off: nothing is posted
        #expect(delivery.records.map { "\($0.channel.rawValue):\($0.outcome.rawValue):\($0.failureReason ?? "")" }
            == ["local:skipped:category"])
    }

    @Test("a category the Mac turned off is still returned for the phones, which apply their own switches")
    func macSwitchesDoNotSilenceThePhone() async {
        let spy = SpyNotifier()
        let c = NotificationCoordinator(notifier: spy)
        var prefs = NotificationCategoryPrefs.default
        prefs.set(NotificationSound.agentDone, enabled: false)
        let t0 = Date(timeIntervalSince1970: 0)
        await c.observe([session("done", .working, since: t0)], now: t0,
                        appActive: false, quietMode: false, categories: prefs)
        let earned = await c.observe([session("done", .done, since: t0.addingTimeInterval(60))],
                                     now: t0.addingTimeInterval(60),
                                     appActive: false, quietMode: false, categories: prefs)
        #expect(spy.played.isEmpty)                                   // this Mac: switch off, nothing posted
        #expect(earned.map { "\($0.sessionID):\($0.sound.rawValue)" } == ["done:agent_done"])  // phones decide for themselves
    }

    @Test("a reminder re-posts agent_done, but not with the category off or in Focus mode")
    func remindHonoursCategoriesAndFocus() async {
        let spy = SpyNotifier()
        let c = NotificationCoordinator(notifier: spy)
        var done = session("s", .done)
        done.hasUnreadCompletion = true
        done.attention = .followed
        #expect(await c.remind(done, quietMode: false))
        #expect(spy.played.map { "\($0.id):\($0.sound.rawValue)" } == ["s:agent_done"])

        var off = NotificationCategoryPrefs.default
        off.set(NotificationSound.agentDone, enabled: false)
        #expect(await c.remind(done, quietMode: false, categories: off) == false)
        #expect(await c.remind(done, quietMode: true) == false)
        #expect(spy.played.count == 1)
    }

    @Test("a waiting cue is withdrawn once its session stops waiting; a completion stays")
    func withdrawsResolvedWaits() async {
        let spy = SpyNotifier()
        let c = NotificationCoordinator(notifier: spy)
        let t0 = Date(timeIntervalSince1970: 1_000)
        await c.observe([session("q", .working, since: t0), session("d", .working, since: t0)],
                        now: t0, appActive: false, quietMode: false)
        await c.observe([session("q", .needsResponse, wait: .question, since: t0),
                         session("d", .done, since: t0)],
                        now: t0.addingTimeInterval(60), appActive: false, quietMode: false)
        #expect(spy.withdrawn.isEmpty)
        // Answered on the terminal: q is working again, d is still just done.
        await c.observe([session("q", .working, since: t0), session("d", .done, since: t0)],
                        now: t0.addingTimeInterval(61), appActive: false, quietMode: false)
        #expect(spy.withdrawn == [[NotificationIdentity.id(sessionID: "q", sound: .needsAnswer)]])
        // Gone entirely: nothing left to withdraw for q, and d was never tracked.
        await c.observe([], now: t0.addingTimeInterval(62), appActive: false, quietMode: false)
        #expect(spy.withdrawn.count == 1)
    }

    @Test("stays silent for the backlog already waiting on the first snapshot")
    func silentOnFirstSnapshot() async {
        let spy = SpyNotifier()
        let c = NotificationCoordinator(notifier: spy)
        await c.observe([session("a", .needsResponse, wait: .question)], appActive: false, quietMode: false)
        #expect(spy.played.isEmpty)
    }

    @Test("the cues handed back are the ones the notifier was given, so push and local agree")
    func returnsWhatItForwarded() async {
        let spy = SpyNotifier()
        let c = NotificationCoordinator(notifier: spy)
        await c.observe([session("a", .working)], appActive: false, quietMode: false)
        let alerts = await c.observe([session("a", .needsResponse, wait: .permission)],
                                     appActive: false, quietMode: false)
        #expect(alerts.map(\.delivery) == [.bannerSound])
        #expect(alerts.map(\.sessionID) == spy.played.map(\.id))
    }

    @Test("Quiet, foreground, and anti-duplication still skip sends and records")
    func quietForegroundAndDedupStillHold() async {
        let spy = SpyNotifier()
        let delivery = SpyDelivery()
        let c = NotificationCoordinator(notifier: spy, delivery: delivery)
        let t0 = Date(timeIntervalSince1970: 1_000)

        await c.observe([session("q", .working, since: t0), session("d", .working, since: t0),
                         session("r", .working, since: t0)],
                        now: t0, appActive: false, quietMode: true)
        await c.observe([session("q", .needsResponse, wait: .question, since: t0),
                         session("d", .done, since: t0),
                         session("r", .needsResponse, wait: .permission, since: t0)],
                        now: t0.addingTimeInterval(60), appActive: true, quietMode: true)

        // Quiet: the question is listed, the approval banners silently, and the
        // completion is dropped (VibeBuddy is frontmost anyway).
        #expect(spy.played.map { "\($0.id):\($0.sound.rawValue)" } == ["q:needs_answer", "r:needs_approval"])
        #expect(delivery.records.map { "\($0.sessionID ?? ""):\($0.sound ?? ""):\($0.outcome.rawValue)" } == [
            "q:needs_answer:scheduled", "r:needs_approval:scheduled",
        ])

        await c.observe([session("r", .needsResponse, wait: .permission, since: t0)],
                        now: t0.addingTimeInterval(61), appActive: true, quietMode: true)
        #expect(spy.played.count == 2)
        #expect(delivery.records.count == 2)
        #expect(!delivery.records.contains(where: { $0.outcome.rawValue == "delivered" }))
    }

    @Test("records scheduled local delivery with session and sound; permission failure is failed")
    func recordsScheduledAndPermissionFailure() async {
        let spy = SpyNotifier()
        let delivery = SpyDelivery()
        let c = NotificationCoordinator(notifier: spy, delivery: delivery)
        await c.observe([session("a", .working)], appActive: false, quietMode: false)
        await c.observe([session("a", .needsResponse, wait: .permission)], appActive: false, quietMode: false)
        #expect(delivery.records.map(\.outcome) == [.scheduled])
        #expect(delivery.records.first?.sessionID == "a")
        #expect(delivery.records.first?.sound == "needs_approval")
        #expect(delivery.records.first?.channel == .local)
        #expect(delivery.records.first?.outcome.rawValue != "delivered")

        spy.result = .failed(reason: "permissionDenied")
        await c.observe([session("b", .working)], appActive: false, quietMode: false)
        await c.observe([session("a", .needsResponse, wait: .permission),
                         session("b", .needsResponse, wait: .question)],
                        appActive: false, quietMode: false)
        #expect(delivery.records.last?.outcome == .failed)
        #expect(delivery.records.last?.failureReason == "permissionDenied")
        #expect(delivery.records.last?.sessionID == "b")
        #expect(delivery.records.last?.sound == "needs_answer")
        #expect(!delivery.records.contains(where: { $0.outcome.rawValue == "delivered" }))
    }
}
