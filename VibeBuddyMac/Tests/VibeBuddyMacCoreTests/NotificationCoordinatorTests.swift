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
        func notify(_ alert: SoundAlert) async -> LocalNotificationAttempt {
            played.append((alert.sessionID, alert.sound))
            return result
        }
    }

    private func session(_ id: String, _ status: SessionStatus, wait: WaitKind? = nil,
                         agent: AgentKind = .claudeCode,
                         since: Date = Date(timeIntervalSince1970: 0)) -> AgentSession {
        AgentSession(id: id, agent: agent, project: "p",
                     status: status, waitKind: wait, statusSince: since, updatedAt: since)
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

    @Test("a category the Mac turned off is never forwarded; Focus still narrows to approvals")
    func categoriesFilterBeforePosting() async {
        let spy = SpyNotifier()
        let c = NotificationCoordinator(notifier: spy)
        var prefs = NotificationCategoryPrefs.default
        prefs.set(.agentDone, enabled: false)
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

        // Focus mode on top of the categories: only the approval survives.
        let quietSpy = SpyNotifier()
        let q = NotificationCoordinator(notifier: quietSpy)
        await q.observe([session("ask", .working, since: t0), session("ok", .working, since: t0)],
                        now: t0, appActive: false, quietMode: true, categories: prefs)
        await q.observe([session("ask", .needsResponse, wait: .question, since: t0.addingTimeInterval(60)),
                         session("ok", .needsResponse, wait: .permission, since: t0.addingTimeInterval(60))],
                        now: t0.addingTimeInterval(60), appActive: false, quietMode: true, categories: prefs)
        #expect(quietSpy.played.map(\.id) == ["ok"])
    }

    @Test("a reminder re-posts agent_done, but not with the category off or in Focus mode")
    func remindHonoursCategoriesAndFocus() async {
        let spy = SpyNotifier()
        let c = NotificationCoordinator(notifier: spy)
        var done = session("s", .done)
        done.hasUnreadCompletion = true
        done.followed = true
        #expect(await c.remind(done, quietMode: false))
        #expect(spy.played.map { "\($0.id):\($0.sound.rawValue)" } == ["s:agent_done"])

        var off = NotificationCategoryPrefs.default
        off.set(.agentDone, enabled: false)
        #expect(await c.remind(done, quietMode: false, categories: off) == false)
        #expect(await c.remind(done, quietMode: true) == false)
        #expect(spy.played.count == 1)
    }

    @Test("forwards a fresh question transition as needs_answer")
    func forwardsFreshQuestion() async {
        let spy = SpyNotifier()
        let c = NotificationCoordinator(notifier: spy)
        await c.observe([session("a", .working)], appActive: false, quietMode: false)
        await c.observe([session("a", .needsResponse, wait: .question)], appActive: false, quietMode: false)
        #expect(spy.played.map(\.sound) == [.needsAnswer])
        #expect(spy.played.map(\.id) == ["a"])
    }

    @Test("forwards a fresh permission transition as needs_approval")
    func forwardsFreshPermission() async {
        let spy = SpyNotifier()
        let c = NotificationCoordinator(notifier: spy)
        await c.observe([session("a", .working)], appActive: false, quietMode: false)
        await c.observe([session("a", .needsResponse, wait: .permission)], appActive: false, quietMode: false)
        #expect(spy.played.map(\.sound) == [.needsApproval])
    }

    @Test("stays silent for the backlog already waiting on the first snapshot")
    func silentOnFirstSnapshot() async {
        let spy = SpyNotifier()
        let c = NotificationCoordinator(notifier: spy)
        await c.observe([session("a", .needsResponse, wait: .question)], appActive: false, quietMode: false)
        #expect(spy.played.isEmpty)
    }

    @Test("Quiet mode forwards approvals but not questions")
    func quietModeKeepsApprovalsOnly() async {
        let spy = SpyNotifier()
        let c = NotificationCoordinator(notifier: spy)
        await c.observe([session("a", .working), session("b", .working)], appActive: false, quietMode: true)
        await c.observe([session("a", .needsResponse, wait: .question),
                         session("b", .needsResponse, wait: .permission)], appActive: false, quietMode: true)
        #expect(spy.played.map(\.sound) == [.needsApproval])
        #expect(spy.played.map(\.id) == ["b"])
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

        #expect(spy.played.map { "\($0.id):\($0.sound.rawValue)" } == ["r:needs_approval"])
        #expect(delivery.records.map { "\($0.sessionID ?? ""):\($0.sound ?? ""):\($0.outcome.rawValue)" } == [
            "r:needs_approval:scheduled",
        ])

        await c.observe([session("r", .needsResponse, wait: .permission, since: t0)],
                        now: t0.addingTimeInterval(61), appActive: true, quietMode: true)
        #expect(spy.played.count == 1)
        #expect(delivery.records.count == 1)
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
