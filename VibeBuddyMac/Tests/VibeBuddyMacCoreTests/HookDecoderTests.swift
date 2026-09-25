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

    @Test("retired CLI hooks are ignored", arguments: [AgentKind.qwen, .kimi])
    func retiredSources(agent: AgentKind) {
        let result = HookDecoder.decode(
            Data(#"{"hook_event_name":"Stop","session_id":"s"}"#.utf8),
            agent: agent, receivedAt: now)
        #expect(result == .ignored)
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
