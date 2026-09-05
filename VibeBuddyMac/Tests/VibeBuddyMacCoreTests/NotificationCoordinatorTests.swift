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
        private(set) var withdrawn: [[String]] = []
        func notify(_ alert: SoundAlert) async -> LocalNotificationAttempt {
            played.append((alert.sessionID, alert.sound))
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

    @Test("Quiet mode reads every session as muted: a silent approval banner, a listed question")
    func quietModeMutesEverything() async {
        let spy = SpyNotifier()
        let c = NotificationCoordinator(notifier: spy)
        await c.observe([session("a", .working), session("b", .working)], appActive: false, quietMode: true)
        let alerts = await c.observe([session("a", .needsResponse, wait: .question),
                                      session("b", .needsResponse, wait: .permission)],
                                     appActive: false, quietMode: true)
        #expect(alerts.map { "\($0.sessionID):\($0.sound.rawValue):\($0.delivery)" } == [
            "a:needs_answer:list", "b:needs_approval:banner",
        ])
        #expect(spy.played.map(\.id) == ["a", "b"])
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
