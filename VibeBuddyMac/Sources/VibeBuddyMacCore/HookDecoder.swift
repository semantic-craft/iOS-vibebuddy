import Foundation
import VibeBuddyKit

/// Source-aware hook decoding: the `?agent=` value (already mapped to an
/// `AgentKind` at the route) selects which decoder turns the raw hook payload
/// into a normalized `HookEvent`.
///
/// Claude-shape lifecycle hooks (Claude Code, Codex, qwen, kimi, …) are the
/// default/passthrough and need no translation. CLIs with a different wire shape
/// get their own pure decoder dispatched here.
public enum HookDecoder {
    public static func decode(
        _ data: Data,
        agent: AgentKind,
        receivedAt: Date
    ) -> HookEvent? {
        switch agent {
        case .codex:
            return HookParser.parse(data, agent: .codex, receivedAt: receivedAt)
        case .grok:
            // Grok's envelope is camelCase keys with snake_case event values.
            return GrokParser.parse(data, receivedAt: receivedAt)
        case .antigravity:
            // Antigravity/Gemini: Claude-shape envelope but Gemini event names
            // (BeforeTool/AfterAgent/…), plus the Antigravity-2.0 spelling.
            return AntigravityParser.parse(data, receivedAt: receivedAt)
        default:
            return HookParser.parse(data, agent: agent, receivedAt: receivedAt)
        }
    }
}
