import Testing
@testable import VibeBuddyKit

@Suite("ToolActivity — tool name to human phrase")
struct ToolActivityTests {
    private func session(_ status: SessionStatus) -> AgentSession {
        AgentSession(id: "s", agent: .codex, project: "demo", status: status,
                     statusSince: .distantPast, updatedAt: .distantPast)
    }

    @Test("matching is case-insensitive and trims whitespace")
    func caseInsensitive() {
        #expect(ToolActivity.phrase(for: "bash") == "Running")
        #expect(ToolActivity.phrase(for: "EDIT") == "Editing")
        #expect(ToolActivity.phrase(for: "  grep  ") == "Searching")
    }

    @Test("unknown or missing tool returns nil (caller falls back to summary)")
    func unknownNil() {
        #expect(ToolActivity.phrase(for: "Frobnicate") == nil)
        #expect(ToolActivity.phrase(for: nil) == nil)
        #expect(ToolActivity.phrase(for: "") == nil)
        #expect(ToolActivity.phrase(for: "   ") == nil)
    }

    @Test("child summary reports active count, names, and unknown without guessing")
    func childSummary() {
        var withChildren = session(.working)
        withChildren.childAgents = [
            ChildAgent(id: "subagent:a", kind: .subagent, name: "Explore",
                       status: .running, lastActivity: "Grep",
                       updatedAt: .distantPast),
            ChildAgent(id: "task:1", kind: .task, name: "implementer",
                       status: .running, updatedAt: .distantPast),
        ]
        let summary = ToolActivity.childSummary(for: withChildren)
        #expect(summary?.contains("2") == true)
        #expect(summary?.contains("Explore") == true)
        #expect(summary?.contains("implementer") == true)

        var unknown = session(.working)
        unknown.childTopologyDegraded = true
        #expect(ToolActivity.childSummary(for: unknown) == "Subagents unknown")

        #expect(ToolActivity.childSummary(for: session(.working)) == nil)
    }
}
