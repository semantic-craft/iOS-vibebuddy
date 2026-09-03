import Testing
import Foundation
import VibeBuddyKit
@testable import VibeBuddyMacCore

@Suite("Parent/subagent topology (Claude and Grok)")
struct SubagentTopologyTests {

    let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func parse(_ json: String, at offset: TimeInterval = 0) -> HookEvent? {
        HookParser.parse(Data(json.utf8), receivedAt: t0.addingTimeInterval(offset))
    }

    private func reduce(_ jsons: [(String, TimeInterval)]) -> SessionReducer {
        var reducer = SessionReducer()
        for (json, offset) in jsons {
            if let event = parse(json, at: offset) { reducer.apply(event) }
        }
        return reducer
    }

    @Test("stable identities attach concurrent children without merging types")
    func associatesConcurrentChildren() {
        var reducer = reduce([
            (#"{"hook_event_name":"SessionStart","session_id":"parent","cwd":"/x/proj"}"#, 0),
            (#"{"hook_event_name":"UserPromptSubmit","session_id":"parent"}"#, 1),
            (#"{"hook_event_name":"SubagentStart","session_id":"parent","agent_id":"agent-a","agent_type":"Explore"}"#, 2),
            (#"{"hook_event_name":"TaskCreated","session_id":"parent","task_id":"task-001","task_subject":"Implement auth","teammate_name":"implementer","team_name":"session-team"}"#, 3),
        ])

        let session = reducer.sessions["parent"]
        #expect(session?.status == .working)
        #expect(session?.runningChildAgentCount == 2)
        let ids = Set(session?.childAgents?.map(\.id) ?? [])
        #expect(ids == ["subagent:agent-a", "task:task-001"])
        #expect(session?.childAgents?.first { $0.id == "subagent:agent-a" }?.name == "Explore")
        #expect(session?.childAgents?.first { $0.id == "task:task-001" }?.name == "implementer")
        #expect(session?.childAgents?.first { $0.id == "task:task-001" }?.kind == .task)
        #expect(ToolActivity.childSummary(for: session!)?.contains("2") == true)
        #expect(ToolActivity.childSummary(for: session!)?.contains("Explore") == true)
    }

    @Test("duplicate, out-of-order, and missing start/stop do not create running ghosts")
    func noGhostChildren() {
        var reducer = reduce([
            (#"{"hook_event_name":"SessionStart","session_id":"parent"}"#, 0),
            (#"{"hook_event_name":"UserPromptSubmit","session_id":"parent"}"#, 1),
            (#"{"hook_event_name":"SubagentStart","session_id":"parent","agent_id":"agent-a","agent_type":"Explore"}"#, 2),
            (#"{"hook_event_name":"SubagentStart","session_id":"parent","agent_id":"agent-a","agent_type":"Explore"}"#, 3),
        ])
        #expect(reducer.sessions["parent"]?.childAgents?.count == 1)
        #expect(reducer.sessions["parent"]?.runningChildAgentCount == 1)

        if let stop = parse(
            #"{"hook_event_name":"SubagentStop","session_id":"parent","agent_id":"orphan","agent_type":"Plan","last_assistant_message":"done"}"#,
            at: 4
        ) {
            reducer.apply(stop)
        }
        let orphan = reducer.sessions["parent"]?.childAgents?.first { $0.id == "subagent:orphan" }
        #expect(orphan?.status == .completed)
        #expect(reducer.sessions["parent"]?.runningChildAgentCount == 1)

        if let staleStart = parse(
            #"{"hook_event_name":"SubagentStart","session_id":"parent","agent_id":"orphan","agent_type":"Plan"}"#,
            at: 3
        ) {
            reducer.apply(staleStart)
        }
        #expect(reducer.sessions["parent"]?.childAgents?.first { $0.id == "subagent:orphan" }?.status == .completed)
        #expect(reducer.sessions["parent"]?.runningChildAgentCount == 1)

        if let nameless = parse(
            #"{"hook_event_name":"SubagentStart","session_id":"parent"}"#,
            at: 5
        ) {
            reducer.apply(nameless)
        }
        #expect(reducer.sessions["parent"]?.childTopologyDegraded == true)
        #expect(reducer.sessions["parent"]?.runningChildAgentCount == 1)
        #expect(Set(reducer.sessions["parent"]?.childAgents?.map(\.id) ?? []) == [
            "subagent:agent-a", "subagent:orphan"
        ])
    }

    @Test("idle, completion, parent end, and journal restore do not leave permanent running children")
    func endsAndRestoreClearRunning() {
        var reducer = reduce([
            (#"{"hook_event_name":"SessionStart","session_id":"parent"}"#, 0),
            (#"{"hook_event_name":"UserPromptSubmit","session_id":"parent"}"#, 1),
            (#"{"hook_event_name":"TaskCreated","session_id":"parent","task_id":"task-001","teammate_name":"implementer","team_name":"session-team"}"#, 2),
            (#"{"hook_event_name":"SubagentStart","session_id":"parent","agent_id":"agent-a","agent_type":"Explore"}"#, 3),
            (#"{"hook_event_name":"TeammateIdle","session_id":"parent","teammate_name":"implementer","team_name":"session-team"}"#, 4),
            (#"{"hook_event_name":"TaskCompleted","session_id":"parent","task_id":"task-001","teammate_name":"implementer"}"#, 5),
            (#"{"hook_event_name":"SubagentStop","session_id":"parent","agent_id":"agent-a","agent_type":"Explore"}"#, 6),
        ])
        #expect(reducer.sessions["parent"]?.runningChildAgentCount == 0)
        #expect(reducer.sessions["parent"]?.childAgents?.allSatisfy { $0.status != .running } == true)

        var live = reduce([
            (#"{"hook_event_name":"SessionStart","session_id":"parent"}"#, 0),
            (#"{"hook_event_name":"UserPromptSubmit","session_id":"parent"}"#, 1),
            (#"{"hook_event_name":"SubagentStart","session_id":"parent","agent_id":"agent-a","agent_type":"Explore"}"#, 2),
            (#"{"hook_event_name":"SessionEnd","session_id":"parent"}"#, 3),
        ])
        #expect(live.sessions["parent"] == nil)

        var recovered = SessionReducer()
        recovered.restore([
            AgentSession(
                id: "parent", agent: .claudeCode, project: "proj", status: .working,
                childAgents: [
                    ChildAgent(id: "subagent:agent-a", kind: .subagent, name: "Explore",
                               status: .running, updatedAt: t0)
                ],
                childTopologyDegraded: true,
                statusSince: t0, updatedAt: t0)
        ])
        #expect(recovered.sessions["parent"]?.status == .working)
        #expect(recovered.sessions["parent"]?.childAgents == nil || recovered.sessions["parent"]?.childAgents?.isEmpty == true)
        #expect(recovered.sessions["parent"]?.runningChildAgentCount == 0)
        #expect(recovered.sessions["parent"]?.childTopologyDegraded != true)
    }

    @Test("parent three-state stays on parent semantic events")
    func parentStateNotHijacked() {
        var waiting = reduce([
            (#"{"hook_event_name":"SessionStart","session_id":"parent"}"#, 0),
            (#"{"hook_event_name":"Notification","session_id":"parent","message":"Claude needs your permission to use Bash"}"#, 1),
            (#"{"hook_event_name":"SubagentStart","session_id":"parent","agent_id":"agent-a","agent_type":"Explore"}"#, 2),
            (#"{"hook_event_name":"PreToolUse","session_id":"parent","agent_id":"agent-a","tool_name":"Grep"}"#, 3),
            (#"{"hook_event_name":"TaskCreated","session_id":"parent","task_id":"task-001"}"#, 4),
        ])
        let waitingSession = waiting.sessions["parent"]
        #expect(waitingSession?.status == .needsResponse)
        #expect(waitingSession?.waitKind == .permission)
        #expect(waitingSession?.activeTool == nil)
        #expect(waitingSession?.runningChildAgentCount == 2)
        #expect(waitingSession?.childAgents?.first { $0.id == "subagent:agent-a" }?.lastActivity == "Grep")

        var idle = reduce([
            (#"{"hook_event_name":"SessionStart","session_id":"parent"}"#, 0),
            (#"{"hook_event_name":"SubagentStart","session_id":"parent","agent_id":"agent-a","agent_type":"Explore"}"#, 1),
        ])
        #expect(idle.sessions["parent"]?.status == .done)
        #expect(idle.sessions["parent"]?.runningChildAgentCount == 1)

        var working = reduce([
            (#"{"hook_event_name":"SessionStart","session_id":"parent"}"#, 0),
            (#"{"hook_event_name":"UserPromptSubmit","session_id":"parent"}"#, 1),
            (#"{"hook_event_name":"SubagentStart","session_id":"parent","agent_id":"agent-a","agent_type":"Explore"}"#, 2),
            (#"{"hook_event_name":"Stop","session_id":"parent"}"#, 3),
        ])
        #expect(working.sessions["parent"]?.status == .done)
        #expect(working.sessions["parent"]?.runningChildAgentCount == 1)
        #expect(working.sessions["parent"]?.activeTool == nil)
    }

    // MARK: - Grok

    private func grok(_ json: String, at offset: TimeInterval = 0) -> HookEvent? {
        GrokParser.parse(Data(json.utf8), receivedAt: t0.addingTimeInterval(offset)).event
    }

    @Test("Grok subagents produce the same ChildAgent rows as Claude's")
    func grokChildRows() {
        var reducer = SessionReducer()
        for (json, offset) in [
            (#"{"hookEventName":"session_start","sessionId":"parent","cwd":"/x/proj"}"#, 0.0),
            (#"{"hookEventName":"user_prompt_submit","sessionId":"parent","promptId":"p1"}"#, 1.0),
            (#"{"hookEventName":"subagent_start","sessionId":"parent","subagentId":"child-a","subagentType":"explore","description":"Survey"}"#, 2.0),
            (#"{"hookEventName":"subagent_start","sessionId":"parent","subagentId":"child-b","subagentType":"code-reviewer","description":"Review"}"#, 3.0),
        ] {
            if let e = grok(json, at: offset) { reducer.apply(e) }
        }
        let session = reducer.sessions["parent"]
        #expect(session?.status == .working)
        #expect(session?.runningChildAgentCount == 2)
        #expect(Set(session?.childAgents?.map(\.id) ?? []) == ["subagent:child-a", "subagent:child-b"])
        #expect(session?.childAgents?.allSatisfy { $0.kind == .subagent } == true)
        #expect(ToolActivity.childSummary(for: session!)?.contains("2") == true)

        // Each child's stop arrives from the child's own session id.
        for (json, offset) in [
            (#"{"hookEventName":"subagent_stop","sessionId":"child-a","subagentId":"child-a","subagentType":"explore","phase":"gate"}"#, 4.0),
            (#"{"hookEventName":"subagent_stop","sessionId":"child-b","subagentId":"child-b","subagentType":"code-reviewer","phase":"gate"}"#, 5.0),
        ] {
            if let e = grok(json, at: offset) { reducer.apply(e) }
        }
        #expect(reducer.sessions.keys.sorted() == ["parent"])
        #expect(reducer.sessions["parent"]?.runningChildAgentCount == 0)
        #expect(reducer.sessions["parent"]?.status == .working)
    }

    @Test("a duplicate SubagentStop phase does not resurrect or duplicate the child")
    func grokDuplicateStopPhases() {
        var reducer = SessionReducer()
        for (json, offset) in [
            (#"{"hookEventName":"session_start","sessionId":"parent","cwd":"/x/proj"}"#, 0.0),
            (#"{"hookEventName":"subagent_start","sessionId":"parent","subagentId":"child-a","subagentType":"explore"}"#, 1.0),
            (#"{"hookEventName":"subagent_stop","sessionId":"child-a","subagentId":"child-a","subagentType":"explore","phase":"gate"}"#, 2.0),
            (#"{"hookEventName":"subagent_stop","sessionId":"child-a","subagentId":"child-a","subagentType":"explore","phase":"observe"}"#, 3.0),
        ] {
            if let e = grok(json, at: offset) { reducer.apply(e) }
        }
        #expect(reducer.sessions["parent"]?.childAgents?.count == 1)
        #expect(reducer.sessions["parent"]?.runningChildAgentCount == 0)
    }
}
