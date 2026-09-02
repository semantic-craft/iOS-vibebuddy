import Testing
@testable import VibeBuddyKit

@Suite("ToolActivity — tool name to human phrase")
struct ToolActivityTests {
    private func session(_ status: SessionStatus, wait: WaitKind? = nil,
                         failed: Bool = false, tool: String? = nil) -> AgentSession {
        AgentSession(id: "s", agent: .codex, project: "demo", status: status,
                     waitKind: wait, failed: failed, activeTool: tool,
                     statusSince: .distantPast, updatedAt: .distantPast)
    }

    @Test("known tools map to a short activity")
    func knownTools() {
        #expect(ToolActivity.phrase(for: "Edit") == "Editing")
        #expect(ToolActivity.phrase(for: "MultiEdit") == "Editing")
        #expect(ToolActivity.phrase(for: "Read") == "Reading")
        #expect(ToolActivity.phrase(for: "Bash") == "Running")
        #expect(ToolActivity.phrase(for: "Grep") == "Searching")
        #expect(ToolActivity.phrase(for: "WebSearch") == "Browsing")
        #expect(ToolActivity.phrase(for: "Task") == "Delegating")
        #expect(ToolActivity.phrase(for: "TodoWrite") == "Planning")
        #expect(ToolActivity.phrase(for: "collaboration/followup_task") == "Coordinating")
        #expect(ToolActivity.phrase(for: "codex_app/wait_threads") == "Waiting")
        #expect(ToolActivity.phrase(for: "view_image") == "Reading")
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

    @Test("session label makes every monitoring state explicit")
    func sessionLabel() {
        #expect(ToolActivity.label(for: session(.needsResponse, wait: .permission)) == "Needs approval")
        #expect(ToolActivity.label(for: session(.needsResponse, wait: .question)) == "Needs input")
        #expect(ToolActivity.label(for: session(.working, tool: "apply_patch")) == "Editing…")
        #expect(ToolActivity.label(for: session(.working)) == "Working")
        #expect(ToolActivity.label(for: session(.done, failed: true)) == "Stopped with an issue")
        #expect(ToolActivity.label(for: session(.done)) == "Ready")
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
