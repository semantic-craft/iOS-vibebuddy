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
    /// A payload we understood but that carries no status change (grok's
    /// teardown `stop`, anything fired inside a subagent's own session, a
    /// passive audit record) is `.ignored` — distinct from `.undecodable`, which
    /// is the only outcome that means "this CLI speaks a shape we do not know"
    /// and is therefore the only one that may report `unknownVersion` health.
    public enum Result: Equatable, Sendable {
        case event(HookEvent)
        case ignored
        case undecodable

        public var event: HookEvent? {
            if case let .event(event) = self { return event }
            return nil
        }
    }

    public static func decode(
        _ data: Data,
        agent: AgentKind,
        receivedAt: Date
    ) -> Result {
        switch agent {
        case .codex:
            return result(HookParser.parse(data, agent: .codex, receivedAt: receivedAt))
        case .grok:
            // Grok's envelope is camelCase keys with snake_case event values,
            // and it is the one CLI that tells the two outcomes apart.
            return GrokParser.parse(data, receivedAt: receivedAt)
        case .antigravity:
            // Antigravity/Gemini: Claude-shape envelope but Gemini event names
            // (BeforeTool/AfterAgent/…), plus the Antigravity-2.0 spelling.
            return result(AntigravityParser.parse(data, receivedAt: receivedAt))
        default:
            return result(HookParser.parse(data, agent: agent, receivedAt: receivedAt))
        }
    }

    private static func result(_ event: HookEvent?) -> Result {
        event.map(Result.event) ?? .undecodable
    }
}
