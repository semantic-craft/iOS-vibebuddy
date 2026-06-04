import Testing
import Foundation
import VibeBuddyKit

@Suite("SessionFilter")
struct SessionFilterTests {
    private func s(_ id: String, _ status: SessionStatus, agent: AgentKind = .claudeCode,
                   project: String = "proj", summary: String? = nil) -> AgentSession {
        AgentSession(id: id, agent: agent, project: project, status: status,
                     summary: summary, statusSince: Date(timeIntervalSince1970: 0),
                     updatedAt: Date(timeIntervalSince1970: 0))
    }

    @Test("status filter keeps only that status")
    func byStatus() {
        let all = [s("a", .needsResponse), s("b", .working), s("c", .done)]
        let r = SessionFilter.apply(all, status: .working, agent: nil, query: "")
        #expect(r.map(\.id) == ["b"])
    }

    @Test("agent filter keeps only that agent")
    func byAgent() {
        let all = [s("a", .working, agent: .claudeCode), s("b", .working, agent: .codex)]
        #expect(SessionFilter.apply(all, status: nil, agent: .codex, query: "").map(\.id) == ["b"])
    }

    @Test("query matches project or summary, case-insensitively")
    func byQuery() {
        let all = [s("a", .working, project: "iOS-vibebuddy"),
                   s("b", .working, project: "other", summary: "fix the BUG")]
        #expect(SessionFilter.apply(all, status: nil, agent: nil, query: "vibe").map(\.id) == ["a"])
        #expect(SessionFilter.apply(all, status: nil, agent: nil, query: "bug").map(\.id) == ["b"])
    }

    @Test("nil filters + empty query return everything")
    func noFilter() {
        let all = [s("a", .working), s("b", .done)]
        #expect(SessionFilter.apply(all, status: nil, agent: nil, query: "").count == 2)
    }

    @Test("presentAgents lists distinct agents that appear")
    func present() {
        let all = [s("a", .working, agent: .claudeCode), s("b", .done, agent: .codex), s("c", .working, agent: .claudeCode)]
        #expect(Set(SessionFilter.presentAgents(all)) == Set([.claudeCode, .codex]))
    }
}
