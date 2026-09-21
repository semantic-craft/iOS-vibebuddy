import Foundation
import Testing
import VibeBuddyKit
@testable import VibeBuddyMacCore

@Suite("Agent column grouping")
struct DashboardAgentColumnTests {
    private func session(_ id: String, _ status: SessionStatus, at time: TimeInterval = 90,
                         unread: Bool = false) -> AgentSession {
        AgentSession(id: id, agent: .codex, project: "Alpha", status: status,
                     waitKind: status == .needsResponse ? .question : nil,
                     hasUnreadCompletion: unread,
                     statusSince: Date(timeIntervalSince1970: time),
                     updatedAt: Date(timeIntervalSince1970: time))
    }

    @Test func groupsReadInAttentionOrderAndDropEmptyHeadings() {
        let input = [session("done", .done, unread: true),
                     session("needs", .needsResponse),
                     session("working", .working)]
        let groups = DashboardAgentColumn.groups(input)

        #expect(groups.map(\.filter) == [.needsYou, .working, .done])
        #expect(groups.map { $0.sessions.map(\.id) } == [["needs"], ["working"], ["done"]])
        #expect(DashboardAgentColumn.groups([]).isEmpty)
    }

    @Test func groupingKeepsTheOrderItIsGivenAndLeavesTheInputAlone() {
        let input = [session("second", .working, at: 20), session("first", .working, at: 90)]
        let before = input
        #expect(DashboardAgentColumn.groups(input).first?.sessions.map(\.id) == ["second", "first"])
        #expect(input == before)
    }
}
