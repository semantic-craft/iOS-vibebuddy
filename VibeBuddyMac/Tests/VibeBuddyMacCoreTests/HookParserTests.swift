import Testing
import Foundation
import VibeBuddyKit
@testable import VibeBuddyMacCore

@Suite("HookParser — raw Claude Code JSON to HookEvent")
struct HookParserTests {

    let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func parse(_ json: String) -> HookEvent? {
        HookParser.parse(Data(json.utf8), receivedAt: now)
    }

    @Test("parses a PreToolUse payload")
    func preToolUse() {
        let e = parse("""
        {"hook_event_name":"PreToolUse","session_id":"abc",
         "cwd":"/Users/me/projects/vibebuddy","tool_name":"Bash",
         "tool_input":{"command":"ls"}}
        """)
        #expect(e?.kind == .preToolUse)
        #expect(e?.sessionID == "abc")
        #expect(e?.cwd == "/Users/me/projects/vibebuddy")
        #expect(e?.toolName == "Bash")
        #expect(e?.timestamp == now)
    }

    @Test("parses a Notification payload with message")
    func notification() {
        let e = parse("""
        {"hook_event_name":"Notification","session_id":"abc",
         "message":"Claude needs your permission to use Bash"}
        """)
        #expect(e?.kind == .notification)
        #expect(e?.message == "Claude needs your permission to use Bash")
    }

    @Test("PostToolUse with an is_error tool_response is flagged as a tool error")
    func postToolUseError() {
        let e = parse("""
        {"hook_event_name":"PostToolUse","session_id":"abc","tool_name":"Bash",
         "tool_response":{"is_error":true,"stdout":"","stderr":"command not found"}}
        """)
        #expect(e?.kind == .postToolUse)
        #expect(e?.toolError == true)
    }

    @Test("PostToolUse with a string tool_response decodes and is not an error")
    func postToolUseStringResponse() {
        let e = parse("""
        {"hook_event_name":"PostToolUse","session_id":"abc","tool_name":"Read",
         "tool_response":"file contents here"}
        """)
        #expect(e?.kind == .postToolUse)          // a string tool_response must not break decoding
        #expect(e?.toolError == false)
    }

    @Test("a successful PostToolUse is not a tool error")
    func postToolUseSuccess() {
        let e = parse("""
        {"hook_event_name":"PostToolUse","session_id":"abc","tool_name":"Bash",
         "tool_response":{"is_error":false,"stdout":"ok"}}
        """)
        #expect(e?.toolError == false)
    }

    @Test("PostToolUseFailure is normalized as a failed tool completion")
    func postToolUseFailure() {
        let e = parse("""
        {"hook_event_name":"PostToolUseFailure","session_id":"abc","tool_name":"Bash",
         "error":"Process exited with code 1"}
        """)
        #expect(e?.kind == .postToolUse)
        #expect(e?.toolError == true)
        #expect(e?.message == "Process exited with code 1")
    }

    @Test("StopFailure is normalized as a failed completion")
    func stopFailure() {
        let e = parse("""
        {"hook_event_name":"StopFailure","session_id":"abc","error":"API request failed"}
        """)
        #expect(e?.kind == .stop)
        #expect(e?.message == "API request failed")
    }

    @Test("compaction lifecycle stays a parent working-state tool event")
    func compactionLifecycle() {
        let cases: [(String, HookEvent.Kind, String)] = [
            (#"{"hook_event_name":"PreCompact","session_id":"abc"}"#,
             .preToolUse, "Context compaction"),
            (#"{"hook_event_name":"PostCompact","session_id":"abc"}"#,
             .postToolUse, "Context compaction"),
        ]
        for (json, kind, tool) in cases {
            let event = parse(json)
            #expect(event?.kind == kind)
            #expect(event?.toolName == tool)
            #expect(event?.childID == nil)
        }
    }

    @Test("SubagentStart carries a stable child identity instead of a tool label")
    func subagentStartIdentity() {
        let event = parse("""
        {"hook_event_name":"SubagentStart","session_id":"abc",
         "agent_id":"agent-abc123","agent_type":"Explore"}
        """)
        #expect(event?.kind == .childLifecycle)
        #expect(event?.childAction == .started)
        #expect(event?.childID == "subagent:agent-abc123")
        #expect(event?.childKind == .subagent)
        #expect(event?.childName == "Explore")
        #expect(event?.childType == "Explore")
    }

    @Test("SubagentStop without agent_id is still a child event, not a parent tool")
    func subagentStopMissingIdentity() {
        let event = parse(#"{"hook_event_name":"SubagentStop","session_id":"abc","agent_type":"Explore"}"#)
        #expect(event?.kind == .childLifecycle)
        #expect(event?.childAction == .stopped)
        #expect(event?.childID == nil)
        #expect(event?.childKind == .subagent)
    }

    @Test("Elicitation becomes a user-input wait")
    func elicitation() {
        let e = parse("""
        {"hook_event_name":"Elicitation","session_id":"abc","message":"Choose a deployment target"}
        """)
        #expect(e?.kind == .notification)
        #expect(e?.message == "Choose a deployment target")
    }

    @Test("current Claude lifecycle continuations return to working")
    func currentClaudeContinuationEvents() {
        let cases: [(String, String)] = [
            ("ElicitationResult", "MCP elicitation"),
            ("PostToolBatch", "Tool batch"),
        ]
        for (name, tool) in cases {
            let event = parse(#"{"hook_event_name":"\#(name)","session_id":"abc"}"#)
            #expect(event?.kind == .postToolUse)
            #expect(event?.toolName == tool)
        }
    }

    @Test("TaskCreated and TaskCompleted are child lifecycle events")
    func taskLifecycleIdentity() {
        let created = parse("""
        {"hook_event_name":"TaskCreated","session_id":"abc",
         "task_id":"task-001","task_subject":"Implement user authentication",
         "teammate_name":"implementer","team_name":"session-a1b2c3d4"}
        """)
        #expect(created?.kind == .childLifecycle)
        #expect(created?.childAction == .started)
        #expect(created?.childID == "task:task-001")
        #expect(created?.childKind == .task)
        #expect(created?.childName == "implementer")
        #expect(created?.childType == "implementer")

        let completed = parse(#"{"hook_event_name":"TaskCompleted","session_id":"abc","task_id":"task-001"}"#)
        #expect(completed?.kind == .childLifecycle)
        #expect(completed?.childAction == .stopped)
        #expect(completed?.childID == "task:task-001")
    }

    @Test("TeammateIdle is a child idle event keyed by team and name")
    func teammateIdleIdentity() {
        let event = parse("""
        {"hook_event_name":"TeammateIdle","session_id":"abc",
         "teammate_name":"implementer","team_name":"session-team"}
        """)
        #expect(event?.kind == .childLifecycle)
        #expect(event?.childAction == .idled)
        #expect(event?.childID == "teammate:session-team/implementer")
        #expect(event?.childKind == .teammate)
        #expect(event?.childName == "implementer")
    }

    @Test("nested subagent tool events keep parent kind but carry the child id")
    func nestedSubagentToolIdentity() {
        let event = parse("""
        {"hook_event_name":"PreToolUse","session_id":"abc",
         "agent_id":"agent-a","tool_name":"Grep"}
        """)
        #expect(event?.kind == .preToolUse)
        #expect(event?.toolName == "Grep")
        #expect(event?.childID == "subagent:agent-a")
    }

    @Test("PostModelSwitch updates metadata with the canonical target model")
    func postModelSwitch() {
        let event = parse("""
        {"hook_event_name":"PostModelSwitch","session_id":"abc",
         "cwd":"/x/proj","from_model":"claude-sonnet-4-6",
         "to_model":"claude-opus-5","source":"user"}
        """)
        #expect(event?.kind == .sessionMetadataChanged)
        #expect(event?.model == "claude-opus-5")
        #expect(event?.cwd == "/x/proj")
    }

    @Test("CwdChanged uses new_cwd rather than the previous common cwd")
    func cwdChanged() {
        let event = parse("""
        {"hook_event_name":"CwdChanged","session_id":"abc",
         "cwd":"/x/proj/src","old_cwd":"/x/proj","new_cwd":"/x/proj/src"}
        """)
        #expect(event?.kind == .sessionMetadataChanged)
        #expect(event?.cwd == "/x/proj/src")
        #expect(event?.model == nil)
    }

    @Test("Codex Interrupt is normalized as an interrupted completion")
    func codexInterrupt() {
        let e = HookParser.parse(
            Data(#"{"hook_event_name":"Interrupt","session_id":"abc"}"#.utf8),
            agent: .codex,
            receivedAt: now
        )
        #expect(e?.kind == .stop)
        #expect(e?.message == "Turn interrupted")
    }

    @Test("parses a Stop payload")
    func stop() {
        let e = parse("""
        {"hook_event_name":"Stop","session_id":"abc","stop_hook_active":true}
        """)
        #expect(e?.kind == .stop)
        #expect(e?.sessionID == "abc")
    }

    @Test("parses a SessionEnd payload")
    func sessionEnd() {
        let e = parse("""
        {"hook_event_name":"SessionEnd","session_id":"abc","cwd":"/x/proj","reason":"exit"}
        """)
        #expect(e?.kind == .sessionEnd)
        #expect(e?.sessionID == "abc")
        #expect(e?.cwd == "/x/proj")
    }

    @Test("unknown hook_event_name → nil (ignored)")
    func unknownKind() {
        #expect(parse("""
        {"hook_event_name":"FutureTelemetryEvent","session_id":"abc"}
        """) == nil)
    }

    @Test("malformed JSON → nil")
    func malformed() {
        #expect(parse("{not json") == nil)
    }

    @Test("missing session_id → nil")
    func missingSession() {
        #expect(parse("""
        {"hook_event_name":"Stop"}
        """) == nil)
    }

    @Test("parsed events drive the reducer end-to-end")
    func parseThenReduce() {
        var r = SessionReducer()
        let events = [
            parse(#"{"hook_event_name":"SessionStart","session_id":"s","cwd":"/x/proj"}"#),
            parse(#"{"hook_event_name":"Notification","session_id":"s","message":"needs your permission"}"#),
        ].compactMap { $0 }
        #expect(events.count == 2)
        for e in events { r.apply(e) }
        #expect(r.sessions["s"]?.status == .needsResponse)
        #expect(r.sessions["s"]?.waitKind == .permission)
        #expect(r.sessions["s"]?.project == "proj")
    }
}
