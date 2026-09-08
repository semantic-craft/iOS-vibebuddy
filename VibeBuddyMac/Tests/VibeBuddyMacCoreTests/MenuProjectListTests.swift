import Foundation
import Testing
import VibeBuddyKit
@testable import VibeBuddyMacCore

@Suite("Mac menu project presentation")
struct MenuProjectListTests {
    private func session(_ id: String, _ project: String, _ status: SessionStatus = .working) -> AgentSession {
        AgentSession(id: id, agent: .codex, project: project, status: status, statusSince: Date(), updatedAt: Date())
    }

    @Test func visibleProjectsUseStableAttentionPartition() {
        var unread = session("unread", "B", .done)
        unread.hasUnreadCompletion = true
        var error = session("error", "D", .done)
        error.failed = true
        let input = [session("a1", "A"), unread, session("c1", "C"),
                     session("d1", "D"), session("a2", "A", .needsResponse), error,
                     session("c2", "C", .needsResponse), session("a3", "A", .needsResponse),
                     session("a4", "A"), session("e", "E", .done)]
        let list = MenuProjectList(input)
        #expect(list.projects.map(\.title) == ["A", "C", "D", "B", "E"])
        #expect(list.projects[0].actionable.map(\.id) == ["a2", "a3"])
        #expect(list.projects[0].others.map(\.id) == ["a1", "a4"])
        #expect(list.projects[0].count == 4)
        #expect(list.projects[0].visibleSessions.map(\.id) == ["a2", "a3"])
        #expect(list.visibleCount == input.count)
        #expect(list.emptyState == nil)
    }

    @Test func everySessionIsShown() {
        let input = [session("a", "A"), session("b", "B", .done), session("c", "C", .needsResponse)]
        #expect(MenuProjectList(input).visibleCount == 3)
        #expect(MenuProjectList([]).emptyState == .noSessions)
    }

    @Test func newAttentionEscapesCollapseThenReturnsToOrdinaryOrder() throws {
        var b = session("b", "B", .done)
        b.completionID = "round-1"
        let a = session("a", "A")
        #expect(MenuProjectList([a, b]).projects.map(\.title) == ["A", "B"])
        b.status = .needsResponse
        let waiting = MenuProjectList([a, b])
        #expect(waiting.projects.map(\.title) == ["B", "A"])
        #expect(waiting.projects[0].visibleSessions.map(\.id) == ["b"])
        let expanded = Set([waiting.projects[1].expansionKey])
        let restored = try JSONDecoder().decode(Set<String>.self, from: JSONEncoder().encode(expanded))
        b.status = .working
        let resolved = MenuProjectList([a, b], expandedProjects: restored)
        #expect(resolved.projects.map(\.title) == ["A", "B"])
        #expect(resolved.projects[0].visibleSessions.map(\.id) == ["a"])
        #expect(resolved.projects[1].visibleSessions.isEmpty)
    }

    @Test func missingProjectDoesNotCollideWithNamedUnknownProject() {
        let list = MenuProjectList([session("missing", "  "), session("named", "Unknown project"),
                                    session("path1", "/repo/main"), session("path2", "/repo/worktree")])
        #expect(list.projects.count == 4)
        #expect(Set(list.projects.map(\.expansionKey)).count == 4)
    }
}
