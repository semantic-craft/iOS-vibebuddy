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

    @Test func projectSearchAndStateIntersectWithoutChangingTheSnapshot() {
        let input = [session("b", "Beta", .needsResponse), session("old", "Alpha", .working),
                     session("done", "Alpha", .done), session("new", "Alpha", .working, at: 20),
                     session("miss", "Alpha", .working, summary: "different"),
                     session("blank", "  ", .done), session("named", "Unknown project", .done)]
        let before = input
        let list = DashboardSessionList(input, project: .project("Alpha"), status: .thinking, query: "needle")
        #expect(list.visible.map(\.id) == ["new", "old"])
        #expect(list.total == 7)
        #expect(list.projects.first?.count == 7)
        #expect(list.projects.first { $0.id == .project("Alpha") }?.count == 4)
        #expect(list.projects.contains { $0.id == .unknown })
        #expect(list.projects.contains { $0.id == .project("Unknown project") })
        #expect(DashboardSessionList(input).visible.first?.id == "b")
        #expect(input == before)
    }

    @Test func hiddenSelectionClearsWithoutSelectingAnotherAndVisibleRefreshKeepsIdentity() {
        let first = session("selected", "Alpha", .done)
        let other = session("other", "Beta", .needsResponse)
        let input = [first, other]
        #expect(DashboardSessionList(input, selection: "selected").selected?.id == "selected")
        #expect(DashboardSessionList(input, project: .project("Beta"), selection: "selected").selected == nil)
        #expect(DashboardSessionList(input, status: .requiresInput, selection: "selected").selected == nil)
        #expect(DashboardSessionList(input, query: "Beta", selection: "selected").selected == nil)
        #expect(DashboardSessionList(input).selected == nil)
        let updated = session("selected", "Alpha", .working, summary: "new result")
        #expect(DashboardSessionList([updated, other], selection: "selected").selected?.summary == "new result")
        let removed = DashboardSessionList([other], project: .project("Alpha"), selection: "selected")
        #expect(removed.selected == nil)
        #expect(removed.visible.isEmpty)
        #expect(removed.projects.contains { $0.id == .project("Alpha") && $0.count == 0 })
    }
}
