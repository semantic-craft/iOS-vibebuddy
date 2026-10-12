import Foundation
import Testing
@testable import VibeBuddyKit

@Suite("Pending task navigation")
struct PendingTaskNavigationTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    func task(_ id: String, _ status: SessionStatus) -> AgentSession {
        var s = AgentSession(id: id, agent: .claudeCode, project: "p", status: status,
                             hasUnreadCompletion: status == .done, statusSince: now, updatedAt: now)
        s.completionID = status == .done ? id + "-round" : nil
        return s
    }

    @Test("Completed results never inflate pending counts, regardless of legacy read state")
    func completedResultsAreNotPending() {
        let wait = task("wait", .needsResponse)
        var finished = (0..<496).map { task("done-\($0)", .done) }
        finished[0].hasUnreadCompletion = false
        let sessions = finished + [wait, task("wait2", .needsResponse),
                                   task("wait3", .needsResponse), task("wait4", .needsResponse)]
        #expect(PendingTasks.ordered(sessions).count == 4)
        #expect(TaskPresentationSummary(sessions: sessions).pendingCount == 4)
        #expect(StateGroups(sessions).done.count == 496)
        #expect(!RowPresentation(session: finished[1]).unread)
    }

    @Test("Manual selection and new rounds keep a stable order without revisiting the current task")
    func changingCandidates() {
        let a = task("a", .done), b = task("b", .done), c = task("c", .done)
        var tour = PendingTaskNavigation()
        #expect(tour.next(in: [a, b, c], after: b)?.id == "c")
        var newA = a; newA.completionID = "a-new-round"
        #expect(tour.next(in: [newA, b, c], after: c)?.completionID == "a-new-round")
        // A new task is not skipped just because an earlier row was deleted.
        let d = task("d", .done)
        #expect(tour.next(in: [b, d], after: newA)?.id == "d")
    }
    @Test("Phone stops at the end even after reads remove visited tasks")
    func nonWrappingTour() {
        let wait = task("wait", .needsResponse), first = task("first", .done), last = task("last", .done)
        var tour = PendingTaskNavigation()
        tour.select(first, in: [wait, first, last])
        #expect(tour.next(in: [wait, last], after: first, wraps: false)?.id == last.id)
        #expect(tour.next(in: [wait], after: last, wraps: false) == nil)
        var newWait = wait; newWait.statusSince = now.addingTimeInterval(1)
        #expect(tour.next(in: [newWait], after: last, wraps: false)?.id == wait.id)
    }

}
