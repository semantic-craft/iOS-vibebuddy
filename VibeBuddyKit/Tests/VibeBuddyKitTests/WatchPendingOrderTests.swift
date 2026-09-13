import Testing
import Foundation
@testable import VibeBuddyKit

/// One queue on every surface (ticket 03, `.scratch/iphone-board`): the
/// wrist's alerts and results keep the relative order of `PendingTasks.ordered`,
/// the same order the phone's "First up", its "Next" and its read-aloud use.
@Suite("Watch follows the shared pending order")
struct WatchPendingOrderTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func session(_ id: String, _ status: SessionStatus, minutesAgo: Double,
                         unread: Bool = false, failed: Bool = false,
                         approval: Bool = false, question: Bool = false) -> AgentSession {
        let at = now.addingTimeInterval(-minutesAgo * 60)
        var s = AgentSession(id: id, agent: .codex, project: id, status: status,
                             hasUnreadCompletion: unread, statusSince: at, updatedAt: at)
        if unread { s.completionID = id + "-c" }
        if failed { s.failed = true }
        if approval { s.waitKind = .permission; s.pendingApproval = PendingApproval(id: id + "-a", tool: "Bash", commandPreview: "swift test") }
        if question { s.waitKind = .question; s.pendingQuestion = PendingQuestion(id: id + "-q", prompt: "Which?") }
        return s
    }

    @Test("alerts and results are subsequences of the pending queue")
    func wristOrderMatchesPhoneOrder() {
        // Deliberately out of order and with the older question so recency
        // alone would put the approval first.
        let sessions = [session("result-old", .done, minutesAgo: 9, unread: true),
                        session("approve", .needsResponse, minutesAgo: 1, approval: true),
                        session("stuck", .done, minutesAgo: 4, failed: true),
                        session("ask", .needsResponse, minutesAgo: 3, question: true),
                        session("result-new", .done, minutesAgo: 2, unread: true),
                        session("run", .working, minutesAgo: 1)]
        let queue = PendingTasks.ordered(SessionCurrency.current(sessions, now: now)).map(\.id)
        #expect(queue == ["ask", "approve", "stuck", "result-new", "result-old"])

        let state = WatchDashboardProjection.make(snapshot: Snapshot(sessions: sessions, serverTime: now),
                                                  quotas: [], relay: .live, now: now)
        #expect(state.alerts.map(\.sessionId) == ["ask", "approve"], "the first card is the phone's First up")
        #expect(state.results?.map(\.sessionID) == ["stuck", "result-new", "result-old"])
        let wrist = state.alerts.map(\.sessionId) + (state.results ?? []).map(\.sessionID)
        #expect(wrist == queue.filter(wrist.contains), "same relative order, the wrist may only omit")
    }
}
