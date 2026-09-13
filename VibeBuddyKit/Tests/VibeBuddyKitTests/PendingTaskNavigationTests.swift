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

    @Test("Reading removes a result without sending the tour back to an unresolved wait")
    func removedRead() {
        let wait = task("wait", .needsResponse)
        let first = task("first", .done)
        let second = task("second", .done)
        var tour = PendingTaskNavigation()
        let ordered = PendingTasks.ordered([first, second, wait])
        #expect(ordered.map(\.id) == ["wait", "first", "second"])
        #expect(tour.next(in: ordered, after: nil)?.id == "wait")
        #expect(tour.next(in: ordered, after: wait)?.id == "first")
        var read = first; read.hasUnreadCompletion = false
        let remaining = PendingTasks.ordered([read, second, wait])
        #expect(tour.next(in: remaining, after: read)?.id == "second")
        #expect(tour.next(in: [wait], after: second)?.id == "wait")
        #expect(tour.next(in: [wait], after: wait) == nil)
        #expect(tour.next(in: [], after: wait) == nil)
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
}
