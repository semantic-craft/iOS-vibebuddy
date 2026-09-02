import Testing
import Foundation
@testable import VibeBuddyKit

@Suite("BuddyState — aggregate mood from session groups")
struct BuddyStateTests {

    private func session(_ id: String, _ status: SessionStatus,
                         wait: WaitKind? = nil, failed: Bool? = nil,
                         unread: Bool = false,
                         since: TimeInterval = 0) -> AgentSession {
        AgentSession(id: id, agent: .claudeCode, project: id, status: status,
                     waitKind: wait, failed: failed, hasUnreadCompletion: unread,
                     statusSince: Date(timeIntervalSince1970: since),
                     updatedAt: Date(timeIntervalSince1970: since))
    }
    private func groups(_ sessions: AgentSession...) -> SessionGroups { SessionGroups(sessions) }

    @Test("no sessions → sleeping")
    func sleeping() {
        #expect(BuddyState.from(groups()) == .sleeping)
    }

    @Test("a waiting permission reads as approval, beating working and done")
    func approvalWins() {
        let g = groups(session("a", .working), session("b", .done),
                       session("c", .needsResponse, wait: .permission))
        #expect(BuddyState.from(g) == .approval)
    }

    @Test("a waiting question reads as question")
    func question() {
        #expect(BuddyState.from(groups(session("a", .needsResponse, wait: .question))) == .question)
    }

    @Test("a wait past the threshold reads as longWait when time is known")
    func longWait() {
        let g = groups(session("a", .needsResponse, wait: .question, since: 0))
        #expect(BuddyState.from(g, now: Date(timeIntervalSince1970: 300)) == .longWait)
    }

    @Test("working when something runs and nothing needs response")
    func working() {
        #expect(BuddyState.from(groups(session("a", .working), session("b", .done))) == .working)
    }

    @Test("a failed done session reads as stuck")
    func stuck() {
        #expect(BuddyState.from(groups(session("a", .done, failed: true))) == .stuck)
    }

    @Test("done only while a clean completion is unread")
    func done() {
        #expect(BuddyState.from(groups(session("a", .done, unread: true))) == .done)
        #expect(BuddyState.from(groups(session("a", .done))) == .idle)
    }

    @Test("error beats a simultaneous input wait")
    func errorWins() {
        #expect(BuddyState.from(groups(
            session("waiting", .needsResponse, wait: .permission),
            session("failed", .done, failed: true)
        )) == .stuck)
    }

    @Test("approval, question, and long wait share the amber task state")
    func inputMoodsSharePresentation() {
        #expect(BuddyState.approval.presentationState == .requiresInput)
        #expect(BuddyState.question.presentationState == .requiresInput)
        #expect(BuddyState.longWait.presentationState == .requiresInput)
    }
}
