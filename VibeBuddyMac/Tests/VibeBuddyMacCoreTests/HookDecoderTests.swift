import Testing
import Foundation
import VibeBuddyKit
@testable import VibeBuddyMacCore

/// The source-aware seam: the `?agent=` value selects a per-source decoder.
/// Claude-shape is the default/passthrough; specific wire shapes (Codex, Grok)
/// get their own pure decoder. Adding a source = one `case` + one decoder + one
/// test — this suite is the pattern #04/#05 copy.
@Suite("HookDecoder — source-aware dispatch")
struct HookDecoderTests {

    let now = Date(timeIntervalSince1970: 1_700_000_000)

    @Test("claude source decodes the Claude-shape envelope and carries the tag")
    func claudeShape() {
        let e = HookDecoder.decode(
            Data(#"{"hook_event_name":"PreToolUse","session_id":"abc","cwd":"/x/proj","tool_name":"Bash"}"#.utf8),
            agent: .claudeCode, receivedAt: now)
        #expect(e?.kind == .preToolUse)
        #expect(e?.sessionID == "abc")
        #expect(e?.agent == .claudeCode)
    }

    @Test("a claude-shape fork (qwen) decodes via the default passthrough, tagged qwen")
    func defaultPassthroughTag() {
        let e = HookDecoder.decode(
            Data(#"{"hook_event_name":"Stop","session_id":"s"}"#.utf8),
            agent: .qwen, receivedAt: now)
        #expect(e?.kind == .stop)
        #expect(e?.agent == .qwen)
    }

    @Test("codex source routes to the Codex notify decoder, tagged codex")
    func codexRoute() {
        let e = HookDecoder.decode(
            Data(#"{"type":"agent-turn-complete","thread-id":"t1","last-assistant-message":"done"}"#.utf8),
            agent: .codex, receivedAt: now)
        #expect(e?.kind == .stop)
        #expect(e?.agent == .codex)
        #expect(e?.sessionID == "t1")
    }

    @Test("a Codex notify still decodes under a claude-shape source (defensive fallback, unchanged)")
    func codexFallbackUnderDefault() {
        // Preserves today's cascade: claude-shape parse first, Codex notify as fallback.
        let e = HookDecoder.decode(
            Data(#"{"type":"agent-turn-complete","thread-id":"t9"}"#.utf8),
            agent: .claudeCode, receivedAt: now)
        #expect(e?.kind == .stop)
        #expect(e?.sessionID == "t9")
    }

    @Test("grok source routes to the Grok decoder, tagged grok")
    func grokRoute() {
        let e = HookDecoder.decode(
            Data(#"{"hookEventName":"pre_tool_use","sessionId":"g1","cwd":"/x/proj","toolName":"run_terminal_cmd"}"#.utf8),
            agent: .grok, receivedAt: now)
        #expect(e?.kind == .preToolUse)
        #expect(e?.agent == .grok)
        #expect(e?.sessionID == "g1")
        #expect(e?.toolName == "run_terminal_cmd")
    }

    @Test("antigravity source routes to the Antigravity decoder, tagged antigravity")
    func antigravityRoute() {
        let e = HookDecoder.decode(
            Data(#"{"hook_event_name":"BeforeTool","session_id":"a1","cwd":"/x/proj","tool_name":"run_shell_command"}"#.utf8),
            agent: .antigravity, receivedAt: now)
        #expect(e?.kind == .preToolUse)
        #expect(e?.agent == .antigravity)
        #expect(e?.sessionID == "a1")
    }

    @Test("malformed input → nil (fail-open)")
    func malformed() {
        #expect(HookDecoder.decode(Data("{not json".utf8), agent: .grok, receivedAt: now) == nil)
    }
}
