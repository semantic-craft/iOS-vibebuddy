import Testing
import Foundation
import VibeBuddyKit
@testable import VibeBuddyMacCore

/// Grok Build's hook envelope is camelCase keys with snake_case event values,
/// unlike the Claude shape. Envelopes below are recorded from
/// `~/.grok/docs/user-guide/10-hooks.md` (grok 0.2.22).
@Suite("GrokParser — Grok camelCase hook envelope")
struct GrokParserTests {

    let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func parse(_ json: String) -> HookEvent? {
        GrokParser.parse(Data(json.utf8), receivedAt: now)
    }

    @Test("decodes the recorded pre_tool_use envelope → preToolUse tagged grok")
    func recordedPreToolUse() {
        // Verbatim from grok's hooks doc (the "Writing Hook Scripts → Input" example).
        let e = parse(#"""
        {"hookEventName":"pre_tool_use","sessionId":"abc-123",
         "cwd":"/Users/you/project","workspaceRoot":"/Users/you/project",
         "toolName":"run_terminal_cmd","toolInput":{"command":"npm test"},
         "timestamp":"2026-04-14T12:00:00Z"}
        """#)
        #expect(e?.kind == .preToolUse)
        #expect(e?.sessionID == "abc-123")
        #expect(e?.agent == .grok)
        #expect(e?.cwd == "/Users/you/project")
        #expect(e?.toolName == "run_terminal_cmd")
        #expect(e?.toolError == false)
        #expect(e?.timestamp == now)
    }

    @Test("session_start → sessionStart")
    func sessionStart() {
        let e = parse(#"{"hookEventName":"session_start","sessionId":"s","cwd":"/x/proj"}"#)
        #expect(e?.kind == .sessionStart)
        #expect(e?.sessionID == "s")
        #expect(e?.cwd == "/x/proj")
    }

    @Test("falls back to workspaceRoot when cwd is absent")
    func workspaceRootFallback() {
        let e = parse(#"{"hookEventName":"stop","sessionId":"s","workspaceRoot":"/ws/root"}"#)
        #expect(e?.kind == .stop)
        #expect(e?.cwd == "/ws/root")
    }

    @Test("post_tool_use with toolResult.isError → flagged as a tool error")
    func toolResultError() {
        let e = parse(#"""
        {"hookEventName":"post_tool_use","sessionId":"s","toolName":"run_terminal_cmd",
         "toolResult":{"isError":true,"output":"command not found"}}
        """#)
        #expect(e?.kind == .postToolUse)
        #expect(e?.toolError == true)
    }

    @Test("post_tool_use_failure event → postToolUse flagged as a tool error")
    func postToolUseFailureEvent() {
        let e = parse(#"{"hookEventName":"post_tool_use_failure","sessionId":"s","toolName":"run_terminal_cmd"}"#)
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

    @Test("unknown event (pre_compact) → nil (ignored)")
    func unknownEvent() {
        #expect(parse(#"{"hookEventName":"pre_compact","sessionId":"s"}"#) == nil)
    }

    @Test("notification (grok hook-execution telemetry) → nil — not a user prompt")
    func notificationTelemetryIgnored() {
        // Grok fires `notification` to REPORT hook executions, not to ask the user
        // anything (recorded live: it echoed the `stop` hooks running). Treating it
        // as needsResponse would wrongly override `stop`→done and pollute summary.
        let e = parse(#"""
        {"hookEventName":"notification","sessionId":"g",
         "message":"SessionNotification { update: HookExecution { event_name: \"stop\" } }"}
        """#)
        #expect(e == nil)
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
            parse(#"{"hookEventName":"session_start","sessionId":"g","cwd":"/x/proj"}"#),
            parse(#"{"hookEventName":"user_prompt_submit","sessionId":"g"}"#),
            parse(#"{"hookEventName":"stop","sessionId":"g"}"#),
        ].compactMap { $0 }
        #expect(events.count == 3)
        for e in events { r.apply(e) }
        #expect(r.sessions["g"]?.agent == .grok)
        #expect(r.sessions["g"]?.project == "proj")
        #expect(r.sessions["g"]?.status == .done)
    }
}
