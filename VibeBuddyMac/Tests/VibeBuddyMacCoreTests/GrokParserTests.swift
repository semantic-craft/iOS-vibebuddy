import Testing
import Foundation
import VibeBuddyKit
@testable import VibeBuddyMacCore

/// Grok Build's hook envelope is camelCase keys with snake_case event values,
/// unlike the Claude shape. Envelopes below are synthesized from grok 1.0.13's
/// `HookEventEnvelope` / `HookPayload` (`xai-grok-hooks/src/event.rs`) and the
/// shipped hooks guide (`~/.grok/docs/user-guide/10-hooks.md`).
@Suite("GrokParser — Grok camelCase hook envelope")
struct GrokParserTests {

    let now = Date(timeIntervalSince1970: 1_700_000_000)

    /// The decoded event, or nil for both "understood and skipped" and
    /// "not a grok envelope" — `HookDecoderTests` pins which is which.
    private func parse(_ json: String) -> HookEvent? {
        GrokParser.parse(Data(json.utf8), receivedAt: now).event
    }

    // MARK: - Envelope basics

    @Test("decodes the recorded pre_tool_use envelope → preToolUse tagged grok")
    func recordedPreToolUse() {
        let e = parse(#"""
        {"hookEventName":"pre_tool_use","sessionId":"abc-123",
         "cwd":"/Users/you/project","workspaceRoot":"/Users/you/project",
         "promptId":"prompt-1","toolName":"run_terminal_command",
         "toolInput":{"command":"npm test"},"toolUseId":"call-1",
         "toolInputTruncated":false,"timestamp":"2026-04-14T12:00:00Z"}
        """#)
        #expect(e?.kind == .preToolUse)
        #expect(e?.sessionID == "abc-123")
        #expect(e?.agent == .grok)
        #expect(e?.cwd == "/Users/you/project")
        #expect(e?.toolName == "run_terminal_command")   // raw name; normalization is the approval path's job
        #expect(e?.toolError == false)
        #expect(e?.turnID == "prompt-1")
        #expect(e?.timestamp == now)
    }

    @Test("session_start carries modelId and transcriptPath")
    func sessionStart() {
        let e = parse(#"""
        {"hookEventName":"session_start","sessionId":"s","cwd":"/x/proj",
         "source":"startup","modelId":"grok-4.6","agentType":"grok-build-plan",
         "transcriptPath":"/Users/you/.grok/sessions/%2Fx%2Fproj/s/updates.jsonl"}
        """#)
        #expect(e?.kind == .sessionStart)
        #expect(e?.sessionID == "s")
        #expect(e?.cwd == "/x/proj")
        #expect(e?.model == "grok-4.6")
        #expect(e?.transcriptPath == "/Users/you/.grok/sessions/%2Fx%2Fproj/s/updates.jsonl")
    }

    @Test("falls back to workspaceRoot when cwd is absent")
    func workspaceRootFallback() {
        let e = parse(#"{"hookEventName":"stop","sessionId":"s","workspaceRoot":"/ws/root"}"#)
        #expect(e?.kind == .stop)
        #expect(e?.cwd == "/ws/root")
    }

    // MARK: - Tools

    @Test("post_tool_use with toolResult.isError → flagged as a tool error")
    func toolResultError() {
        let e = parse(#"""
        {"hookEventName":"post_tool_use","sessionId":"s","toolName":"run_terminal_command",
         "toolResult":{"isError":true,"output":"command not found"}}
        """#)
        #expect(e?.kind == .postToolUse)
        #expect(e?.toolError == true)
    }

    @Test("post_tool_use_failure event → postToolUse flagged as a tool error")
    func postToolUseFailureEvent() {
        let e = parse(#"""
        {"hookEventName":"post_tool_use_failure","sessionId":"s",
         "toolName":"run_terminal_command","error":"exit status 1","isInterrupt":false}
        """#)
        #expect(e?.kind == .postToolUse)
        #expect(e?.toolError == true)
    }

    @Test("a successful post_tool_use is not a tool error")
    func postToolUseSuccess() {
        let e = parse(#"{"hookEventName":"post_tool_use","sessionId":"s","toolResult":{"isError":false}}"#)
        #expect(e?.kind == .postToolUse)
        #expect(e?.toolError == false)
    }

    @Test("a string toolResult decodes and is not an error")
    func stringToolResult() {
        // toolResult shape varies by tool; a non-object must not break decoding.
        let e = parse(#"{"hookEventName":"post_tool_use","sessionId":"s","toolResult":"plain output"}"#)
        #expect(e?.kind == .postToolUse)
        #expect(e?.toolError == false)
    }

    // MARK: - Notifications

    @Test("notification permission_prompt → a permission wait")
    func permissionPrompt() {
        let e = parse(#"""
        {"hookEventName":"notification","sessionId":"g","notificationType":"permission_prompt",
         "message":"Tool permission requested","level":"info"}
        """#)
        #expect(e?.kind == .notification)
        #expect(e?.message == "Tool permission requested")
        #expect(SessionReducer.waitKind(from: e?.message) == .permission)
    }

    @Test("a permission_prompt whose display text omits the word still reads as a permission wait")
    func permissionPromptWording() {
        // grok fires permission_prompt for plan approval too, with prose that
        // never says "permission" — the reducer infers the wait kind from text.
        let e = parse(#"""
        {"hookEventName":"notification","sessionId":"g","notificationType":"permission_prompt",
         "message":"Plan approval requested"}
        """#)
        #expect(e?.kind == .notification)
        #expect(e?.message == "Permission required: Plan approval requested")
        #expect(SessionReducer.waitKind(from: e?.message) == .permission)
    }

    @Test("notification idle_prompt → an unconditional idle settle")
    func idlePrompt() {
        // The documented backstop: fires ~1 min after ANY turn end, carries no
        // promptId, and is cancelled by the next prompt.
        let e = parse(#"""
        {"hookEventName":"notification","sessionId":"g","notificationType":"idle_prompt",
         "message":"Waiting for your next prompt","level":"info"}
        """#)
        #expect(e?.kind == .stop)
        #expect(e?.turnID == nil)
    }

    @Test("notification task_complete → nil (a background task, not the turn)")
    func taskCompleteIgnored() {
        // A background shell/monitor task can finish mid-turn; settling on it
        // would show a false idle while the agent is still working.
        let e = parse(#"""
        {"hookEventName":"notification","sessionId":"g","notificationType":"task_complete",
         "message":"Background task completed: task-7"}
        """#)
        #expect(e == nil)
    }

    // MARK: - Turn ends

    @Test("stop end_turn carries lastAssistantMessage as the summary")
    func stopEndTurn() {
        let e = parse(#"""
        {"hookEventName":"stop","sessionId":"g","promptId":"prompt-2","reason":"end_turn",
         "stopHookActive":false,"lastAssistantMessage":"All tests pass.",
         "backgroundTasks":[],"sessionCrons":[]}
        """#)
        #expect(e?.kind == .stop)
        #expect(e?.message == "All tests pass.")
        #expect(e?.turnID == "prompt-2")
    }

    @Test("the teardown stop (channel_closed / shutdown) is ignored")
    func stopTeardownIgnored() {
        // grok fires `stop` a second time at teardown; session_end already
        // reports that, and settling on it would resurrect a closed session.
        #expect(parse(#"{"hookEventName":"stop","sessionId":"g","reason":"channel_closed"}"#) == nil)
        #expect(parse(#"{"hookEventName":"stop","sessionId":"g","reason":"shutdown"}"#) == nil)
    }

    @Test("stop_failure settles the turn and reads as failed")
    func stopFailure() {
        let e = parse(#"""
        {"hookEventName":"stop_failure","sessionId":"g","promptId":"p1","error":"rate_limit",
         "errorDetails":"429 from upstream","lastAssistantMessage":"Rate limited."}
        """#)
        #expect(e?.kind == .stop)
        #expect(e?.message == "Turn failed (rate_limit): 429 from upstream")
        // The session is marked failed *only* because the heuristic matches this
        // synthesized prose — grok's envelope carries no failure flag — so both
        // spellings of the message are pinned against the shared marker list.
        #expect(FailureHeuristic.looksFailed("Turn failed (rate_limit): 429 from upstream"))
        #expect(FailureHeuristic.looksFailed("Turn failed: unknown"))

        var reducer = SessionReducer()
        reducer.apply(parse(#"{"hookEventName":"user_prompt_submit","sessionId":"g","promptId":"p1"}"#)!)
        reducer.apply(e!)
        #expect(reducer.sessions["g"]?.status == .done)
        #expect(reducer.sessions["g"]?.failed == true)
    }

    @Test("stop_cancelled settles the turn without marking it failed")
    func stopCancelled() {
        let e = parse(#"""
        {"hookEventName":"stop_cancelled","sessionId":"g","promptId":"p1","reason":"permission_rejected",
         "cancelledBy":"user","lastAssistantMessage":"Stopped before the edit."}
        """#)
        #expect(e?.kind == .stop)
        #expect(e?.message == "Stopped before the edit.")

        var reducer = SessionReducer()
        reducer.apply(parse(#"{"hookEventName":"user_prompt_submit","sessionId":"g","promptId":"p1"}"#)!)
        reducer.apply(e!)
        #expect(reducer.sessions["g"]?.status == .done)
        #expect(reducer.sessions["g"]?.failed != true)
    }

    @Test("a cancelled turn's report that lands after the next prompt is ignored")
    func staleStopCancelledIgnored() {
        // grok dispatches StopCancelled off the command loop, so it can arrive
        // after the user already sent the next prompt. promptId disambiguates.
        var reducer = SessionReducer()
        for json in [
            #"{"hookEventName":"session_start","sessionId":"g","cwd":"/x/proj"}"#,
            #"{"hookEventName":"user_prompt_submit","sessionId":"g","promptId":"p1"}"#,
            #"{"hookEventName":"user_prompt_submit","sessionId":"g","promptId":"p2"}"#,
            #"{"hookEventName":"stop_cancelled","sessionId":"g","promptId":"p1","reason":"user_interrupt","cancelledBy":"user"}"#,
        ] {
            reducer.apply(parse(json)!)
        }
        #expect(reducer.sessions["g"]?.status == .working)

        reducer.apply(parse(#"{"hookEventName":"stop","sessionId":"g","promptId":"p2","reason":"end_turn"}"#)!)
        #expect(reducer.sessions["g"]?.status == .done)
    }

    // MARK: - Subagents

    @Test("subagent_start / subagent_stop drive parent topology, never parent status")
    func subagentTopology() {
        var reducer = SessionReducer()
        for json in [
            #"{"hookEventName":"session_start","sessionId":"parent","cwd":"/x/proj"}"#,
            #"{"hookEventName":"user_prompt_submit","sessionId":"parent","promptId":"p1"}"#,
            #"{"hookEventName":"subagent_start","sessionId":"parent","subagentId":"child-1","subagentType":"explore","description":"Survey the repo"}"#,
        ] {
            reducer.apply(parse(json)!)
        }
        let running = reducer.sessions["parent"]
        #expect(running?.status == .working)
        #expect(running?.runningChildAgentCount == 1)
        #expect(running?.childAgents?.first?.id == "subagent:child-1")
        #expect(running?.childAgents?.first?.kind == .subagent)
        #expect(running?.childAgents?.first?.name == "explore")
        #expect(running?.childAgents?.first?.lastActivity == "Survey the repo")

        // subagent_stop fires inside the CHILD's own session; it must complete the
        // parent's row rather than publish the child as a session of its own.
        let stop = GrokParser.parse(Data(#"""
        {"hookEventName":"subagent_stop","sessionId":"child-1","subagentId":"child-1",
         "subagentType":"explore","phase":"gate","lastAssistantMessage":"Found 3 call sites."}
        """#.utf8), receivedAt: now.addingTimeInterval(5)).event!
        #expect(stop.kind == .childLifecycle)
        #expect(stop.childAction == .stopped)
        reducer.apply(stop)
        #expect(reducer.sessions["child-1"] == nil)
        #expect(reducer.sessions["parent"]?.runningChildAgentCount == 0)
        #expect(reducer.sessions["parent"]?.childAgents?.first?.status == .completed)
        #expect(reducer.sessions["parent"]?.status == .working)
    }

    @Test("an unplaceable subagent_stop does not publish the child as its own session")
    func orphanSubagentStop() {
        var reducer = SessionReducer()
        reducer.apply(GrokParser.parse(Data(#"""
        {"hookEventName":"subagent_stop","sessionId":"child-9","subagentId":"child-9",
         "subagentType":"explore","phase":"gate"}
        """#.utf8), receivedAt: now).event!)
        #expect(reducer.sessions.isEmpty)
    }

    @Test("an ordinary event from a subagent's own session is ignored")
    func childSessionEventIgnored() {
        // Every event that can fire inside a subagent carries subagentType there
        // and omits it in the main session.
        #expect(parse(#"{"hookEventName":"post_tool_use","sessionId":"child-1","toolName":"read_file","subagentType":"explore"}"#) == nil)
        #expect(parse(#"{"hookEventName":"stop_failure","sessionId":"child-1","error":"server_error","subagentType":"explore"}"#) == nil)
        #expect(parse(#"{"hookEventName":"session_end","sessionId":"child-1","reason":"exit","subagentType":"explore"}"#) == nil)
    }

    // MARK: - Ignored and malformed

    @Test("passive-only events are ignored")
    func passiveEventsIgnored() {
        #expect(parse(#"{"hookEventName":"pre_compact","sessionId":"s","source":"auto"}"#) == nil)
        #expect(parse(#"{"hookEventName":"post_compact","sessionId":"s","source":"auto"}"#) == nil)
        #expect(parse(#"{"hookEventName":"permission_denied","sessionId":"s","toolName":"run_terminal_command"}"#) == nil)
    }

    @Test("a Claude-shape payload → nil (wrong parser)")
    func notGrok() {
        #expect(parse(#"{"hook_event_name":"Stop","session_id":"s"}"#) == nil)
    }

    @Test("missing sessionId → nil")
    func missingSession() {
        #expect(parse(#"{"hookEventName":"stop"}"#) == nil)
    }

    @Test("malformed JSON → nil")
    func malformed() {
        #expect(parse("{not json") == nil)
    }

    @Test("parsed Grok events drive the reducer: a turn ends done, tagged grok")
    func endToEnd() {
        var r = SessionReducer()
        let events = [
            parse(#"{"hookEventName":"session_start","sessionId":"g","cwd":"/x/proj","modelId":"grok-4.6"}"#),
            parse(#"{"hookEventName":"user_prompt_submit","sessionId":"g","promptId":"p1"}"#),
            parse(#"{"hookEventName":"stop","sessionId":"g","promptId":"p1","reason":"end_turn"}"#),
        ].compactMap { $0 }
        #expect(events.count == 3)
        for e in events { r.apply(e) }
        #expect(r.sessions["g"]?.agent == .grok)
        #expect(r.sessions["g"]?.project == "proj")
        #expect(r.sessions["g"]?.model == "grok-4.6")
        #expect(r.sessions["g"]?.status == .done)
    }
}
