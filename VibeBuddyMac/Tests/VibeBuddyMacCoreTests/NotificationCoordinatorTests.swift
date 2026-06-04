import Testing
import Foundation
import VibeBuddyKit
@testable import VibeBuddyMacCore

@Suite("NotificationCoordinator — fires only on fresh needsResponse transitions")
struct NotificationCoordinatorTests {

    /// Records which session ids it was asked to notify about.
    final class SpyNotifier: AttentionNotifier {
        private(set) var notified: [String] = []
        func notify(_ session: AgentSession) { notified.append(session.id) }
    }

    private func session(_ id: String, _ status: SessionStatus) -> AgentSession {
        let t0 = Date(timeIntervalSince1970: 0)
        return AgentSession(id: id, agent: .claudeCode, project: "p",
                            status: status, statusSince: t0, updatedAt: t0)
    }

    @Test("fires when a session newly enters needsResponse")
    func firesForNewlyWaiting() {
        let spy = SpyNotifier()
        let c = NotificationCoordinator(notifier: spy)
        c.observe([session("a", .working)])            // first snapshot
        c.observe([session("a", .needsResponse)])      // a transitions
        #expect(spy.notified == ["a"])
    }

    @Test("stays silent for sessions already waiting on the first snapshot")
    func silentOnFirstSnapshotBacklog() {
        let spy = SpyNotifier()
        let c = NotificationCoordinator(notifier: spy)
        c.observe([session("a", .needsResponse), session("b", .needsResponse)])
        #expect(spy.notified.isEmpty)
    }

    @Test("does not re-fire while a session keeps waiting")
    func noRefireWhileWaiting() {
        let spy = SpyNotifier()
        let c = NotificationCoordinator(notifier: spy)
        c.observe([session("a", .working)])
        c.observe([session("a", .needsResponse)])      // fire
        c.observe([session("a", .needsResponse)])      // still waiting → no fire
        #expect(spy.notified == ["a"])
    }

    @Test("re-fires after a session leaves and re-enters needsResponse")
    func refiresAfterReentry() {
        let spy = SpyNotifier()
        let c = NotificationCoordinator(notifier: spy)
        c.observe([session("a", .working)])
        c.observe([session("a", .needsResponse)])      // fire
        c.observe([session("a", .working)])            // left
        c.observe([session("a", .needsResponse)])      // re-entered → fire again
        #expect(spy.notified == ["a", "a"])
    }
}
