import Foundation
import Testing
import VibeBuddyKit
@testable import VibeBuddyMacCore

@Suite("Agent rail and column projection")
struct DashboardAgentColumnTests {
    private func session(_ id: String, _ agent: AgentKind, _ status: SessionStatus,
                         at time: TimeInterval = 90, unread: Bool = false,
                         wait: WaitKind? = nil) -> AgentSession {
        AgentSession(id: id, agent: agent, project: "Alpha", status: status,
                     waitKind: wait ?? (status == .needsResponse ? .question : nil),
                     hasUnreadCompletion: unread,
                     statusSince: Date(timeIntervalSince1970: time),
                     updatedAt: Date(timeIntervalSince1970: time))
    }

    private let now = Date(timeIntervalSince1970: 100)

    @Test func railLeadsWithAllAgentsAndTalliesEachOne() {
        let input = [session("a", .claudeCode, .needsResponse),
                     session("b", .claudeCode, .working),
                     session("c", .claudeCode, .done, unread: true),
                     session("d", .codex, .working)]
        let items = DashboardAgentColumn.items(input, now: now)

        #expect(items.map(\.id) == ["all", "claudeCode", "codex"])
        #expect(items[0].tally == .init(total: 4, needsYou: 1, working: 2, unread: 1))
        #expect(items[1].tally == .init(total: 3, needsYou: 1, working: 1, unread: 1))
        #expect(items[2].tally == .init(total: 1, needsYou: 0, working: 1, unread: 0))
    }

    @Test func theSelectedAgentStaysOnTheRailAfterItsLastSessionAgesOut() {
        let input = [session("d", .codex, .working)]
        #expect(DashboardAgentColumn.items(input, now: now).map(\.id) == ["all", "codex"])
        #expect(DashboardAgentColumn.items(input, keeping: .grok, now: now).map(\.id) == ["all", "codex", "grok"])
        // The kept agent is listed with nothing under it, not with a borrowed count.
        #expect(DashboardAgentColumn.items(input, keeping: .grok, now: now).last?.tally == .init())
    }

    @Test func groupsReadInAttentionOrderAndDropEmptyHeadings() {
        let input = [session("done", .codex, .done, unread: true),
                     session("needs", .codex, .needsResponse),
                     session("working", .codex, .working)]
        let groups = DashboardAgentColumn.groups(input)

        #expect(groups.map(\.filter) == [.needsYou, .working, .done])
        #expect(groups.map { $0.sessions.map(\.id) } == [["needs"], ["working"], ["done"]])
        #expect(DashboardAgentColumn.groups([]).isEmpty)
    }

    @Test func groupingKeepsTheOrderItIsGivenAndLeavesTheInputAlone() {
        let input = [session("second", .codex, .working, at: 20),
                     session("first", .codex, .working, at: 90)]
        let before = input
        #expect(DashboardAgentColumn.groups(input).first?.sessions.map(\.id) == ["second", "first"])
        #expect(input == before)
    }
}
