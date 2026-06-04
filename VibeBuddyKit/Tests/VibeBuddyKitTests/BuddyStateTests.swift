import Testing
import Foundation
@testable import VibeBuddyKit

@Suite("BuddyState — aggregate mood from session groups")
struct BuddyStateTests {

    private func session(_ id: String, _ status: SessionStatus) -> AgentSession {
        AgentSession(id: id, agent: .claudeCode, project: id, status: status,
                     statusSince: Date(timeIntervalSince1970: 0),
                     updatedAt: Date(timeIntervalSince1970: 0))
    }
    private func groups(_ sessions: AgentSession...) -> SessionGroups { SessionGroups(sessions) }

    @Test("no sessions → sleeping")
    func sleeping() {
        #expect(BuddyState.from(groups()) == .sleeping)
    }

    @Test("any needsResponse wins over working and done")
    func needsResponseWins() {
        let g = groups(session("a", .working), session("b", .done), session("c", .needsResponse))
        #expect(BuddyState.from(g) == .needsResponse)
    }

    @Test("working when something runs and nothing needs response")
    func working() {
        #expect(BuddyState.from(groups(session("a", .working), session("b", .done))) == .working)
    }

    @Test("done when only finished sessions remain")
    func done() {
        #expect(BuddyState.from(groups(session("a", .done))) == .done)
    }
}
