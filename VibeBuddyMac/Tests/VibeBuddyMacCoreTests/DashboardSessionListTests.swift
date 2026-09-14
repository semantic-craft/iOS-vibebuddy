import Foundation
import Testing
import VibeBuddyKit
@testable import VibeBuddyMacCore

@Suite("Dashboard project projection")
struct DashboardSessionListTests {
    private func session(_ id: String, _ project: String, _ status: SessionStatus,
                         at time: TimeInterval = 10, summary: String = "needle") -> AgentSession {
        AgentSession(id: id, agent: .codex, project: project, status: status,
                     summary: summary, hasUnreadCompletion: status == .done,
                     statusSince: Date(timeIntervalSince1970: time), updatedAt: Date(timeIntervalSince1970: time))
    }

    private func projection(_ sessions: [AgentSession], project: DashboardSessionList.ProjectScope = .all,
                            status: DashboardSessionList.StatusFilter? = nil, query: String = "", selection: String? = nil,
                            showOlder: Bool = false, recentDirectories: [String] = []) -> DashboardSessionList {
        DashboardSessionList(sessions, project: project, status: status, query: query, selection: selection,
                             showOlder: showOlder, recentDirectories: recentDirectories, now: Date(timeIntervalSince1970: 100))
    }

    @Test func projectSearchAndStateIntersectWithoutChangingTheSnapshot() {
        let input = [session("b", "Beta", .needsResponse), session("old", "Alpha", .working),
                     session("done", "Alpha", .done), session("new", "Alpha", .working, at: 20),
                     session("miss", "Alpha", .working, summary: "different"),
                     session("blank", "  ", .done), session("named", "Unknown project", .done)]
        let before = input
        let list = projection(input, project: .project("Alpha"), status: .working, query: "needle")
        #expect(list.visible.map(\.id) == ["new", "old"])
        #expect(list.total == 7)
        #expect(list.projects.first?.count == 4)
        #expect(list.projects.first { $0.id == .project("Alpha") }?.count == 1)
        #expect(list.projects.contains { $0.id == .unknown })
        #expect(list.projects.contains { $0.id == .project("Unknown project") })
        #expect(projection(input).visible.first?.id == "b")
        #expect(input == before)
    }

    @Test func hiddenSelectionRetainsLiveDetailWithoutSelectingAnother() {
        let first = session("selected", "Alpha", .done)
        let other = session("other", "Beta", .needsResponse)
        let input = [first, other]
        #expect(projection(input, selection: "selected").selected?.id == "selected")
        #expect(projection(input, project: .project("Beta"), selection: "selected").selected?.id == "selected")
        #expect(projection(input, status: .needsYou, selection: "selected").selected?.id == "selected")
        #expect(projection(input, query: "Beta", selection: "selected").selected?.id == "selected")
        #expect(projection(input).selected == nil)
        let updated = session("selected", "Alpha", .working, summary: "new result")
        #expect(projection([updated, other], selection: "selected").selected?.summary == "new result")
        let removed = projection([other], project: .project("Alpha"), selection: "selected")
        #expect(removed.selected == nil)
        #expect(removed.visible.isEmpty)
        #expect(removed.projects.contains { $0.id == .project("Alpha") && $0.count == 0 })
    }

    @Test func needsYouCoversQuestionsAndFailuresLikeEveryOtherSurface() {
        var broke = session("broke", "Alpha", .done)
        broke.failed = true
        let input = [session("ask", "Alpha", .needsResponse), broke,
                     session("busy", "Alpha", .working), session("done", "Alpha", .done)]
        let needsYou = projection(input, status: .needsYou)
        #expect(needsYou.visible.map(\.id) == ["ask", "broke"])
        #expect(projection(input, status: .working).visible.map(\.id) == ["busy"])
        #expect(projection(input, status: .done).visible.map(\.id) == ["done"])
        #expect(DashboardSessionList.StatusFilter.allCases.flatMap(\.states).count
                == Set(DashboardSessionList.StatusFilter.allCases.flatMap(\.states)).count)
    }

    @Test func inboxCountsStayCurrentAndGlobalWithExactPendingOrder() {
        var ask = session("ask", "/one/shared", .needsResponse)
        ask.waitKind = .question
        let approval = session("approve", "/two/shared", .needsResponse)
        var failed = session("failed", "/one/shared", .done)
        failed.failed = true
        var read = session("read", "/read", .done)
        read.hasUnreadCompletion = false
        var old = session("old", "/old", .done, at: -100_000)
        old.attentionOverride = .normal
        let input = [failed, approval, ask, session("done1", "/one/shared", .done),
                     session("done2", "", .done), session("working1", "/one/shared", .working),
                     session("working2", "/two/shared", .working), session("working3", "/third", .working), read, old]
        let list = projection(input, project: .project("/one/shared"), status: .done, query: "needle",
                              recentDirectories: ["/recent"])
        #expect(list.total == 9)
        #expect(list.summary.needsYou == 3)
        #expect(list.summary.completeUnread == 2)
        #expect(list.summary.thinking == 3)
        #expect(list.globalPending.map(\.id) == ["ask", "approve", "failed", "done1", "done2"])
        #expect(list.pending.map(\.id) == ["done1"])
        #expect(list.projects.dropFirst().prefix(2).map(\.id) == [.project("/one/shared"), .project("/two/shared")])
        #expect(list.projects.first { $0.id == .project("/one/shared") }?.count == 3)
        #expect(list.projects.contains { $0.id == .unknown && $0.count == 1 })
        #expect(list.projects.contains { $0.id == .project("/recent") && $0.count == 0 })
        #expect(list.olderCount == 1)
        #expect(projection(input, status: .idle).visible.map(\.id) == ["read"])
        let older = projection(input, project: .project("/old"), status: .done, showOlder: true)
        #expect(older.visible.map(\.id) == ["old"])
        #expect(older.pending.map(\.id) == ["old"])
        #expect(older.total == 9)
        var branch = input[5]
        branch.branch = "codex/inbox"
        #expect(projection([branch], query: "inbox").visible.map(\.id) == [branch.id])
    }

    @Test func scopedTourKeepsReadingSelectionAndRecognizesANewRound() {
        let ask = session("ask", "Alpha", .needsResponse)
        var first = session("first", "Alpha", .done)
        first.completionID = "round-1"
        let second = session("second", "Alpha", .done)
        let otherProject = session("elsewhere", "Beta", .needsResponse)
        var input = [ask, first, second, otherProject]
        var manualTour = PendingTaskNavigation()
        let initial = projection(input, project: .project("Alpha"))
        manualTour.select(first, in: initial.pending)
        var manuallyRead = input
        manuallyRead[1].hasUnreadCompletion = false
        let afterManualRead = projection(manuallyRead, project: .project("Alpha"), selection: first.id)
        #expect(manualTour.next(in: afterManualRead.pending, after: afterManualRead.selected)?.id == second.id)
        var tour = PendingTaskNavigation()
        let scoped = projection(input, project: .project("Alpha"), query: "needle", selection: ask.id)
        #expect(tour.next(in: scoped.pending, after: ask)?.id == first.id)
        input[1].hasUnreadCompletion = false
        let read = projection(input, project: .project("Alpha"), query: "needle", selection: first.id)
        #expect(read.selected?.id == first.id)
        #expect(tour.next(in: read.pending, after: read.selected)?.id == second.id)
        input[1].hasUnreadCompletion = true
        input[1].completionID = "round-2"
        input[1].statusSince = Date(timeIntervalSince1970: 30)
        let nextRound = projection(input, project: .project("Alpha"), query: "needle", selection: second.id)
        #expect(tour.next(in: nextRound.pending, after: second)?.completionID == "round-2")
        let removed = projection(input.filter { $0.id != first.id }, status: .done, selection: first.id)
        #expect(removed.selected == nil)
        #expect(projection(input, status: .working).pending.isEmpty)
    }

    @Test func checkoutIdentityJoinsRecentDirectoriesWithoutMergingSameNamedProjects() {
        var first = session("first-checkout", "results", .done)
        first.checkoutPath = "/tmp/vb-fixture/results"
        var sibling = session("second-checkout", "results", .needsResponse)
        sibling.checkoutPath = "/tmp/other-worktree/results"
        var cloud = session("cloud", "owner/repository", .working)
        cloud.checkoutPath = "  "
        let unknown = session("unassigned", "", .working)
        let input = [first, sibling, cloud, unknown]
        let list = projection(input, recentDirectories: ["/tmp/vb-fixture/results", "/tmp/other-worktree/results"])
        #expect(list.projects.filter { $0.id == .project("/tmp/vb-fixture/results") }.count == 1)
        #expect(list.projects.first { $0.id == .project("/tmp/vb-fixture/results") }?.count == 1)
        #expect(list.projects.first { $0.id == .project("/tmp/other-worktree/results") }?.count == 1)
        #expect(!list.projects.contains { $0.id == .project("results") })
        #expect(list.projects.contains { $0.id == .project("owner/repository") })
        #expect(list.projects.contains { $0.id == .unknown })
        #expect(projection(input, project: .project("/tmp/vb-fixture/results")).visible.map(\.id) == [first.id])
        #expect(projection(input, project: .project("/tmp/other-worktree/results")).pending.map(\.id) == [sibling.id])
        #expect(projection(input, query: "vb-fixture/results").visible.map(\.id) == [first.id])
        #expect(list.summary.pendingCount == 2)
    }

}
