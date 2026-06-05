import Testing
import Foundation
@testable import VibeBuddyKit

@Suite("SessionGroups")
struct SessionGroupsTests {

    private func session(_ id: String, _ status: SessionStatus) -> AgentSession {
        AgentSession(id: id, agent: .claudeCode, project: id, status: status,
                     statusSince: Date(timeIntervalSince1970: 0),
                     updatedAt: Date(timeIntervalSince1970: 0))
    }

    @Test("splits sessions into three buckets, preserving order")
    func splits() {
        let groups = SessionGroups([
            session("a", .needsResponse),
            session("b", .working),
            session("c", .done),
            session("d", .working),
        ])
        #expect(groups.needsResponse.map(\.id) == ["a"])
        #expect(groups.working.map(\.id) == ["b", "d"])
        #expect(groups.done.map(\.id) == ["c"])
    }

    @Test("isEmpty reflects whether there are any sessions")
    func empty() {
        #expect(SessionGroups([]).isEmpty)
        #expect(!SessionGroups([session("a", .done)]).isEmpty)
    }

    @Test("focusSessionId prefers the top needs-response session")
    func focusPrefersNeedsResponse() {
        let groups = SessionGroups([
            session("w", .working),
            session("n", .needsResponse),
            session("d", .done),
        ])
        #expect(groups.focusSessionId == "n")
    }

    @Test("focusSessionId falls back to working, then done")
    func focusFallsBack() {
        #expect(SessionGroups([session("w", .working), session("d", .done)]).focusSessionId == "w")
        #expect(SessionGroups([session("d", .done)]).focusSessionId == "d")
        #expect(SessionGroups([]).focusSessionId == nil)
    }
}
