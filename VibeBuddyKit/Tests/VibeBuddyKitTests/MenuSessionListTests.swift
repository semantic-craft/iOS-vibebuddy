import Testing
import Foundation
@testable import VibeBuddyKit

@Suite("MenuSessionList")
struct MenuSessionListTests {

    private func session(_ id: String, _ agent: AgentKind, _ status: SessionStatus,
                         unread: Bool = false, age: TimeInterval = 0) -> AgentSession {
        let t = Date(timeIntervalSince1970: 1_000_000 - age)
        return AgentSession(id: id, agent: agent, project: id, status: status,
                            waitKind: status == .needsResponse ? .permission : nil,
                            hasUnreadCompletion: unread, statusSince: t, updatedAt: t)
    }

    @Test("sessions that need the user are pinned above every group")
    func pinned() {
        let list = MenuSessionList([
            session("approve", .claudeCode, .needsResponse),
            session("cx-work", .codex, .working),
            session("cc-done", .claudeCode, .done, unread: true),
        ], collapsedAgents: [])
        #expect(list.pinned.map(\.id) == ["approve"])
        #expect(list.groups.map(\.agent) == [.codex, .claudeCode])
        #expect(list.groups.flatMap(\.sessions).map(\.id) == ["cx-work", "cc-done"])
    }

    @Test("groups sort by their most urgent row, then recency")
    func groupOrder() {
        let list = MenuSessionList([
            session("cc-work", .claudeCode, .working, age: 60),
            session("cx-work", .codex, .working, age: 10),
            session("cc-done", .claudeCode, .done, unread: true),
        ], collapsedAgents: [])
        #expect(list.groups.map(\.agent) == [.codex, .claudeCode])
    }

    @Test("a collapsed group keeps its working rows and hides finished ones")
    func collapsedKeepsWorking() {
        let list = MenuSessionList([
            session("cx-work", .codex, .working),
            session("cx-done", .codex, .done, unread: true),
            session("cx-idle", .codex, .done),
            session("cc-done", .claudeCode, .done, unread: true),
        ], collapsedAgents: [.codex])
        let codex = list.groups.first { $0.agent == .codex }!
        #expect(codex.isCollapsed)
        #expect(codex.visibleSessions.map(\.id) == ["cx-work"])
        #expect(codex.summary.completeUnread == 1 && codex.summary.idle == 1 && codex.summary.thinking == 1)
        let claude = list.groups.first { $0.agent == .claudeCode }!
        #expect(!claude.isCollapsed)
        #expect(claude.visibleSessions.map(\.id) == ["cc-done"])
    }

    @Test("a single agent shows no headers and ignores collapsing")
    func singleAgent() {
        let list = MenuSessionList([
            session("a", .codex, .working),
            session("b", .codex, .done, unread: true),
        ], collapsedAgents: [.codex])
        #expect(!list.showsGroupHeaders)
        #expect(list.groups.count == 1)
        #expect(!list.groups[0].isCollapsed)
        #expect(list.groups[0].visibleSessions.map(\.id) == ["a", "b"])
    }
}
