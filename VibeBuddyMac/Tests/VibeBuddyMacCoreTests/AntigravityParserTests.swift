import Testing
import Foundation
import VibeBuddyKit
@testable import VibeBuddyMacCore

/// Antigravity (`agy`) emits the Gemini-CLI hook envelope: snake_case Claude-shape
/// (`hook_event_name`, `session_id`, `cwd`, `tool_name`, `tool_response.error`),
/// differing from Claude only in the event *names*. The decoder accepts both the
/// Gemini-native family (`BeforeTool`/`AfterTool`/`BeforeAgent`/`AfterAgent`) and
/// the Antigravity-2.0 Claude-style spelling (`PreToolUse`/`PostToolUse`/`Stop`),
/// since the live `agy` build's spelling is confirmed via its `/hooks` TUI.
@Suite("AntigravityParser — Gemini/Antigravity hook envelope")
struct AntigravityParserTests {

    let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func parse(_ json: String) -> HookEvent? {
        AntigravityParser.parse(Data(json.utf8), receivedAt: now)
    }

    // MARK: Gemini-native event names

    @Test("Gemini BeforeTool → preToolUse, tagged antigravity")
    func geminiBeforeTool() {
        let e = parse(#"""
        {"hook_event_name":"BeforeTool","session_id":"a1","cwd":"/Users/me/projects/app",
         "tool_name":"run_shell_command","tool_input":{"command":"ls"},
         "timestamp":"2026-06-06T12:00:00Z"}
        """#)
        #expect(e?.kind == .preToolUse)
        #expect(e?.sessionID == "a1")
        #expect(e?.agent == .antigravity)
        #expect(e?.cwd == "/Users/me/projects/app")
        #expect(e?.toolName == "run_shell_command")
        #expect(e?.toolError == false)
    }

    @Test("Gemini SessionStart → sessionStart")
    func geminiSessionStart() {
        let e = parse(#"{"hook_event_name":"SessionStart","session_id":"a","cwd":"/x/proj"}"#)
        #expect(e?.kind == .sessionStart)
        #expect(e?.cwd == "/x/proj")
    }

    @Test("Gemini BeforeAgent → userPromptSubmit")
    func geminiBeforeAgent() {
        #expect(parse(#"{"hook_event_name":"BeforeAgent","session_id":"a"}"#)?.kind == .userPromptSubmit)
    }

    @Test("Gemini AfterAgent → stop")
    func geminiAfterAgent() {
        #expect(parse(#"{"hook_event_name":"AfterAgent","session_id":"a"}"#)?.kind == .stop)
    }

    @Test("Gemini SessionEnd → sessionEnd")
    func geminiSessionEnd() {
        #expect(parse(#"{"hook_event_name":"SessionEnd","session_id":"a","cwd":"/x/proj"}"#)?.kind == .sessionEnd)
    }

    @Test("Gemini AfterTool with tool_response.error → flagged as a tool error")
    func geminiAfterToolError() {
        let e = parse(#"""
        {"hook_event_name":"AfterTool","session_id":"a","tool_name":"run_shell_command",
         "tool_response":{"error":{"message":"command failed"},"returnDisplay":"err"}}
        """#)
        #expect(e?.kind == .postToolUse)
        #expect(e?.toolError == true)
    }

    @Test("Gemini AfterTool success (no error) → not a tool error")
    func geminiAfterToolSuccess() {
        let e = parse(#"""
        {"hook_event_name":"AfterTool","session_id":"a","tool_name":"read_file",
         "tool_response":{"llmContent":"file contents","returnDisplay":"ok"}}
        """#)
        #expect(e?.kind == .postToolUse)
        #expect(e?.toolError == false)
    }

    // MARK: Antigravity-2.0 Claude-style spelling (must also be accepted)

    @Test("Antigravity-2.0 PreToolUse → preToolUse")
    func antigravity2PreToolUse() {
        #expect(parse(#"{"hook_event_name":"PreToolUse","session_id":"a","tool_name":"Bash"}"#)?.kind == .preToolUse)
    }

    @Test("Antigravity-2.0 PostToolUse / Stop / UserPromptSubmit map through")
    func antigravity2Family() {
        #expect(parse(#"{"hook_event_name":"PostToolUse","session_id":"a"}"#)?.kind == .postToolUse)
        #expect(parse(#"{"hook_event_name":"Stop","session_id":"a"}"#)?.kind == .stop)
        #expect(parse(#"{"hook_event_name":"UserPromptSubmit","session_id":"a"}"#)?.kind == .userPromptSubmit)
    }

    // MARK: agy 1.0.5 actual events (confirmed via the live /hooks TUI)

    @Test("agy PreInvocation → userPromptSubmit (working — agy has no SessionStart)")
    func agyPreInvocation() {
        let e = parse(#"{"hook_event_name":"PreInvocation","session_id":"a","cwd":"/x/proj"}"#)
        #expect(e?.kind == .userPromptSubmit)
        #expect(e?.agent == .antigravity)
        #expect(e?.cwd == "/x/proj")
    }

    @Test("agy PostInvocation → nil (redundant — PreInvocation + tool events already mark working)")
    func agyPostInvocation() {
        #expect(parse(#"{"hook_event_name":"PostInvocation","session_id":"a"}"#) == nil)
    }

    @Test("agy 1.0.5 lifecycle drives the reducer: PreInvocation→tools→Stop ends done")
    func agyLifecycle() {
        var r = SessionReducer()
        let events = [
            parse(#"{"hook_event_name":"PreInvocation","session_id":"a","cwd":"/x/proj"}"#),
            parse(#"{"hook_event_name":"PreToolUse","session_id":"a","tool_name":"run_terminal_cmd"}"#),
            parse(#"{"hook_event_name":"PostToolUse","session_id":"a","tool_name":"run_terminal_cmd","tool_response":{"llmContent":"ok"}}"#),
            parse(#"{"hook_event_name":"Stop","session_id":"a"}"#),
        ].compactMap { $0 }
        #expect(events.count == 4)
        for e in events { r.apply(e) }
        #expect(r.sessions["a"]?.agent == .antigravity)
        #expect(r.sessions["a"]?.project == "proj")
        #expect(r.sessions["a"]?.status == .done)
    }

    // MARK: Edges

    @Test("unknown event (BeforeModel / PreCompress) → nil (ignored)")
    func unknownEvents() {
        #expect(parse(#"{"hook_event_name":"BeforeModel","session_id":"a"}"#) == nil)
        #expect(parse(#"{"hook_event_name":"PreCompress","session_id":"a"}"#) == nil)
    }

    @Test("missing session_id → nil")
    func missingSession() {
        #expect(parse(#"{"hook_event_name":"AfterAgent"}"#) == nil)
    }

    @Test("malformed JSON → nil")
    func malformed() {
        #expect(parse("{not json") == nil)
    }

    @Test("parsed Antigravity events drive the reducer: a turn ends done, tagged antigravity")
    func endToEnd() {
        var r = SessionReducer()
        let events = [
            parse(#"{"hook_event_name":"SessionStart","session_id":"a","cwd":"/x/proj"}"#),
            parse(#"{"hook_event_name":"BeforeAgent","session_id":"a"}"#),
            parse(#"{"hook_event_name":"AfterAgent","session_id":"a"}"#),
        ].compactMap { $0 }
        #expect(events.count == 3)
        for e in events { r.apply(e) }
        #expect(r.sessions["a"]?.agent == .antigravity)
        #expect(r.sessions["a"]?.project == "proj")
        #expect(r.sessions["a"]?.status == .done)
    }
}
