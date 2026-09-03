import Testing
import Foundation
import VibeBuddyKit
@testable import VibeBuddyMacCore

/// The source-aware seam: the `?agent=` value selects a per-source decoder.
/// Claude-shape lifecycle hooks are the default/passthrough; sources such as
/// Grok with a different wire shape get their own pure decoder.
@Suite("HookDecoder — source-aware dispatch")
struct HookDecoderTests {

    let now = Date(timeIntervalSince1970: 1_700_000_000)

    @Test("claude source decodes the Claude-shape envelope and carries the tag")
    func claudeShape() {
        let e = HookDecoder.decode(
            Data(#"{"hook_event_name":"PreToolUse","session_id":"abc","cwd":"/x/proj","tool_name":"Bash"}"#.utf8),
            agent: .claudeCode, receivedAt: now).event
        #expect(e?.kind == .preToolUse)
        #expect(e?.sessionID == "abc")
        #expect(e?.agent == .claudeCode)
    }

    @Test("a claude-shape fork (qwen) decodes via the default passthrough, tagged qwen")
    func defaultPassthroughTag() {
        let e = HookDecoder.decode(
            Data(#"{"hook_event_name":"Stop","session_id":"s"}"#.utf8),
            agent: .qwen, receivedAt: now).event
        #expect(e?.kind == .stop)
        #expect(e?.agent == .qwen)
    }

    @Test("codex source decodes first-class lifecycle hooks, tagged codex")
    func codexRoute() {
        let e = HookDecoder.decode(
            Data(#"{"hook_event_name":"PreToolUse","session_id":"t1","cwd":"/x/proj","tool_name":"Bash"}"#.utf8),
            agent: .codex, receivedAt: now).event
        #expect(e?.kind == .preToolUse)
        #expect(e?.agent == .codex)
        #expect(e?.sessionID == "t1")
        #expect(e?.toolName == "Bash")
    }

    @Test("Codex PermissionRequest becomes a permission wait")
    func codexPermissionRequest() {
        let e = HookDecoder.decode(
            Data(#"{"hook_event_name":"PermissionRequest","session_id":"t9","cwd":"/x/proj","tool_name":"Bash"}"#.utf8),
            agent: .codex, receivedAt: now).event
        #expect(e?.kind == .notification)
        #expect(e?.sessionID == "t9")
        #expect(e?.message == "Permission required for Bash")
    }

    @Test("Codex Stop carries the last assistant message")
    func codexStopSummary() {
        let e = HookDecoder.decode(
            Data(#"{"hook_event_name":"Stop","session_id":"t10","cwd":"/x/proj","last_assistant_message":"All tests pass."}"#.utf8),
            agent: .codex, receivedAt: now).event
        #expect(e?.kind == .stop)
        #expect(e?.message == "All tests pass.")
    }

    @Test("grok source routes to the Grok decoder, tagged grok")
    func grokRoute() {
        let e = HookDecoder.decode(
            Data(#"{"hookEventName":"pre_tool_use","sessionId":"g1","cwd":"/x/proj","toolName":"run_terminal_cmd"}"#.utf8),
            agent: .grok, receivedAt: now).event
        #expect(e?.kind == .preToolUse)
        #expect(e?.agent == .grok)
        #expect(e?.sessionID == "g1")
        #expect(e?.toolName == "run_terminal_cmd")
    }

    @Test("Grok stop carries the last assistant message, like Codex's Stop summary")
    func grokStopSummary() {
        let e = HookDecoder.decode(
            Data(#"{"hookEventName":"stop","sessionId":"g2","cwd":"/x/proj","promptId":"p1","reason":"end_turn","lastAssistantMessage":"All tests pass."}"#.utf8),
            agent: .grok, receivedAt: now).event
        #expect(e?.kind == .stop)
        #expect(e?.message == "All tests pass.")
        #expect(e?.turnID == "p1")
    }

    @Test("Grok's permission_prompt notification becomes a permission wait")
    func grokPermissionPrompt() {
        let e = HookDecoder.decode(
            Data(#"{"hookEventName":"notification","sessionId":"g3","notificationType":"permission_prompt","message":"Tool permission requested"}"#.utf8),
            agent: .grok, receivedAt: now).event
        #expect(e?.kind == .notification)
        #expect(e?.message == "Tool permission requested")
    }

    @Test("Claude-shape turn events carry no turn identity, so they always settle")
    func claudeShapeHasNoTurnID() {
        let e = HookDecoder.decode(
            Data(#"{"hook_event_name":"Stop","session_id":"s"}"#.utf8),
            agent: .claudeCode, receivedAt: now).event
        #expect(e?.kind == .stop)
        #expect(e?.turnID == nil)
    }

    @Test("antigravity source routes to the Antigravity decoder, tagged antigravity")
    func antigravityRoute() {
        let e = HookDecoder.decode(
            Data(#"{"hook_event_name":"BeforeTool","session_id":"a1","cwd":"/x/proj","tool_name":"run_shell_command"}"#.utf8),
            agent: .antigravity, receivedAt: now).event
        #expect(e?.kind == .preToolUse)
        #expect(e?.agent == .antigravity)
        #expect(e?.sessionID == "a1")
    }

    @Test("malformed input is undecodable, not merely ignored")
    func malformed() {
        #expect(HookDecoder.decode(Data("{not json".utf8), agent: .grok, receivedAt: now)
                == .undecodable)
        #expect(HookDecoder.decode(Data("{not json".utf8), agent: .claudeCode, receivedAt: now)
                == .undecodable)
    }

    @Test("a grok event we understand but deliberately skip is ignored, not unknown")
    func grokIgnored() {
        // Fires at EVERY grok session teardown; reporting it as an unknown
        // version would light up "grok hooks: unsupported version" in Settings.
        #expect(HookDecoder.decode(
            Data(#"{"hookEventName":"stop","sessionId":"g4","reason":"shutdown"}"#.utf8),
            agent: .grok, receivedAt: now) == .ignored)
        #expect(HookDecoder.decode(
            Data(#"{"hookEventName":"post_tool_use","sessionId":"c1","subagentType":"explore"}"#.utf8),
            agent: .grok, receivedAt: now) == .ignored)
    }
}
