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

}
