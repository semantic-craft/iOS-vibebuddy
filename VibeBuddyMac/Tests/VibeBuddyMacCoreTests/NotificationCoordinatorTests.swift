import Testing
import Foundation
import VibeBuddyKit
@testable import VibeBuddyMacCore

/// The coordinator is a thin adapter over `SoundPolicy` (whose full rule matrix
/// is tested in VibeBuddyKit). These tests pin the adapter's contract: it
/// forwards the policy's cues to the notifier, stays silent on the opening
/// backlog, and threads Quiet mode through.
@Suite("NotificationCoordinator — forwards SoundPolicy cues")
struct NotificationCoordinatorTests {

    /// Records the sounds it was asked to play, paired with the session id.
    final class SpyNotifier: AttentionNotifier {
        private(set) var played: [(id: String, sound: NotificationSound)] = []
        func notify(_ alert: SoundAlert) { played.append((alert.sessionID, alert.sound)) }
    }

    private func session(_ id: String, _ status: SessionStatus, wait: WaitKind? = nil) -> AgentSession {
        let t0 = Date(timeIntervalSince1970: 0)
        return AgentSession(id: id, agent: .claudeCode, project: "p",
                            status: status, waitKind: wait, statusSince: t0, updatedAt: t0)
    }

    @Test("forwards a fresh question transition as needs_answer")
    func forwardsFreshQuestion() {
        let spy = SpyNotifier()
        let c = NotificationCoordinator(notifier: spy)
        c.observe([session("a", .working)], appActive: false, quietMode: false)
        c.observe([session("a", .needsResponse, wait: .question)], appActive: false, quietMode: false)
        #expect(spy.played.map(\.sound) == [.needsAnswer])
        #expect(spy.played.map(\.id) == ["a"])
    }

    @Test("forwards a fresh permission transition as needs_approval")
    func forwardsFreshPermission() {
        let spy = SpyNotifier()
        let c = NotificationCoordinator(notifier: spy)
        c.observe([session("a", .working)], appActive: false, quietMode: false)
        c.observe([session("a", .needsResponse, wait: .permission)], appActive: false, quietMode: false)
        #expect(spy.played.map(\.sound) == [.needsApproval])
    }

    @Test("stays silent for the backlog already waiting on the first snapshot")
    func silentOnFirstSnapshot() {
        let spy = SpyNotifier()
        let c = NotificationCoordinator(notifier: spy)
        c.observe([session("a", .needsResponse, wait: .question)], appActive: false, quietMode: false)
        #expect(spy.played.isEmpty)
    }

    @Test("Quiet mode forwards approvals but not questions")
    func quietModeKeepsApprovalsOnly() {
        let spy = SpyNotifier()
        let c = NotificationCoordinator(notifier: spy)
        c.observe([session("a", .working), session("b", .working)], appActive: false, quietMode: true)
        c.observe([session("a", .needsResponse, wait: .question),
                   session("b", .needsResponse, wait: .permission)], appActive: false, quietMode: true)
        #expect(spy.played.map(\.sound) == [.needsApproval])
        #expect(spy.played.map(\.id) == ["b"])
    }
}
