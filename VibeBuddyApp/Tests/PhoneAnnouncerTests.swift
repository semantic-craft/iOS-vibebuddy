import XCTest
import VibeBuddyKit
@testable import VibeBuddyApp

/// The phone's read-aloud plan (ticket 04): the pending queue in order, each
/// item bound to its round, so a change between planning and speaking skips
/// the item instead of announcing stale news. No audio is exercised here.
final class PhoneAnnouncerTests: XCTestCase {
    private let now = Date()

    private func session(_ id: String, _ status: SessionStatus, minutesAgo: Double = 1,
                         unread: Bool = false, completion: String? = nil, failed: Bool = false,
                         approval: String? = nil, question: String? = nil) -> AgentSession {
        let at = now.addingTimeInterval(-minutesAgo * 60)
        var s = AgentSession(id: id, agent: .codex, project: id, status: status,
                             hasUnreadCompletion: unread, statusSince: at, updatedAt: at)
        s.completionID = completion
        if failed { s.failed = true }
        if let approval {
            s.waitKind = .permission
            s.pendingApproval = PendingApproval(id: approval, tool: "Bash", commandPreview: "swift test")
        }
        if let question {
            s.waitKind = .question
            s.pendingQuestion = PendingQuestion(id: question, prompt: "Which?")
        }
        return s
    }

    func testPlanFollowsThePendingQueueAndNamesEachRound() {
        let sessions = [session("result", .done, unread: true, completion: "c1"),
                        session("stuck", .done, failed: true),
                        session("ask", .needsResponse, question: "q1"),
                        session("run", .working),
                        session("approve", .needsResponse, approval: "a1")]
        let plan = AnnouncementPlan(pending: PendingTasks.ordered(sessions))
        XCTAssertEqual(plan.items.map(\.sessionID), ["ask", "approve", "stuck", "result"],
                       "questions, then approvals, then failures, then unread results — the shared order")
        XCTAssertEqual(plan.items.map(\.sound), [.needsAnswer, .needsApproval, .agentStuck, .agentDone])
        XCTAssertEqual(plan.items.last?.round, "c1")
        XCTAssertEqual(plan.overflow, 0)
    }

    func testPlanHoldsTenAndCountsTheRest() {
        let sessions = (0..<13).map { session("r\($0)", .done, minutesAgo: Double($0), unread: true, completion: "c\($0)") }
        let plan = AnnouncementPlan(pending: PendingTasks.ordered(sessions))
        XCTAssertEqual(plan.items.count, 10)
        XCTAssertEqual(plan.overflow, 3)
    }

    func testAnItemIsSkippedOnceItsRoundMovedOn() {
        let result = session("result", .done, unread: true, completion: "c1")
        let approve = session("approve", .needsResponse, approval: "a1")
        let plan = AnnouncementPlan(pending: PendingTasks.ordered([result, approve]))
        let resultItem = plan.items.first { $0.sessionID == "result" }!
        let approveItem = plan.items.first { $0.sessionID == "approve" }!

        XCTAssertNotNil(AnnouncementPlan.stillCurrent(resultItem, in: [result, approve]))
        // Read on another device: not news any more.
        var read = result; read.hasUnreadCompletion = false
        XCTAssertNil(AnnouncementPlan.stillCurrent(resultItem, in: [read, approve]))
        // A newer round: the old text would be wrong.
        var next = result; next.completionID = "c2"
        XCTAssertNil(AnnouncementPlan.stillCurrent(resultItem, in: [next, approve]))
        // The approval was answered and the agent carried on.
        let running = session("approve", .working)
        XCTAssertNil(AnnouncementPlan.stillCurrent(approveItem, in: [result, running]))
        // Gone from the snapshot entirely.
        XCTAssertNil(AnnouncementPlan.stillCurrent(approveItem, in: [result]))
    }
}
