import Foundation
import VibeBuddyKit

/// Source-aware hook decoding: the `?agent=` value (already mapped to an
/// `AgentKind` at the route) selects which decoder turns the raw hook payload
/// into a normalized `HookEvent`.
///
/// Claude-shape CLIs (Claude Code and its forks — qwen, kimi, …) are the
/// default/passthrough and need no translation. CLIs with a different wire shape
/// get their own pure decoder dispatched here. **Adding a source is one `case` +
/// one decoder + one test** (see `GrokParser` / `GrokParserTests` for the pattern).
public enum HookDecoder {
    public static func decode(
        _ data: Data,
        agent: AgentKind,
        receivedAt: Date
    ) -> HookEvent? {
        switch agent {
        case .codex:
            // Codex emits its own `notify` envelope, not a Claude-shape hook.
            return CodexParser.parse(data, receivedAt: receivedAt)
        case .grok:
            // Grok's envelope is camelCase keys with snake_case event values.
            return GrokParser.parse(data, receivedAt: receivedAt)
        case .antigravity:
            // Antigravity/Gemini: Claude-shape envelope but Gemini event names
            // (BeforeTool/AfterAgent/…), plus the Antigravity-2.0 spelling.
            return AntigravityParser.parse(data, receivedAt: receivedAt)
        default:
            // Claude-shape passthrough, with Codex notify kept as a defensive
            // fallback so existing flows are byte-for-byte unchanged.
            return HookParser.parse(data, agent: agent, receivedAt: receivedAt)
                ?? CodexParser.parse(data, receivedAt: receivedAt)
        }
    }
}
