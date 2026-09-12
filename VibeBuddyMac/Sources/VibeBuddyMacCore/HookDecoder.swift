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
        case .grokBot: return .undecodable
        case .codex:
            return result(HookParser.parse(data, agent: .codex, receivedAt: receivedAt))
        case .grok:
            // Grok's envelope is camelCase keys with snake_case event values,
            // and it is the one CLI that tells the two outcomes apart.
            return GrokParser.parse(data, receivedAt: receivedAt)
        case .cursor:
            // Cursor: snake_case envelope keyed on `conversation_id`, with
            // camelCase event names (`preToolUse`, `beforeShellExecution`, …).
            return CursorParser.parse(data, receivedAt: receivedAt)
        case .antigravity:
            // Antigravity/Gemini: Claude-shape envelope but Gemini event names
            // (BeforeTool/AfterAgent/…), plus the Antigravity-2.0 spelling.
            return result(AntigravityParser.parse(data, receivedAt: receivedAt))
        default:
            // Cursor calls Claude Code hooks with its *own* payload once the
            // person enables "Include third-party Plugins, Skills, and other
            // configs" (cursor.com/docs/reference/third-party-hooks): the
            // command registered in ~/.claude/settings.json runs with
            // `cursor_version`, `conversation_id` and a camelCase
            // `hook_event_name`, tagged `?agent=claude-code` by the forwarder.
            // Without this sniff one Cursor chat would appear twice — once from
            // ~/.cursor/hooks.json as a Cursor session and once here as a Claude
            // session keyed on a `session_id` Cursor does not send.
            if isCursorEnvelope(data) {
                return CursorParser.parse(data, receivedAt: receivedAt)
            }
            return result(HookParser.parse(data, agent: agent, receivedAt: receivedAt))
        }
    }

    /// Cursor's camelCase hook names (cursor.com/docs/hooks). A Claude-shape
    /// CLI spells its events in PascalCase (`PreToolUse`), so a match here is
    /// unambiguous even when `cursor_version` is absent.
    static let cursorEventNames: Set<String> = [
        "sessionStart", "sessionEnd", "preToolUse", "postToolUse", "postToolUseFailure",
        "beforeShellExecution", "afterShellExecution", "beforeMCPExecution",
        "afterMCPExecution", "beforeReadFile", "afterFileEdit", "beforeSubmitPrompt",
        "preCompact", "stop", "afterAgentResponse", "afterAgentThought",
        "subagentStart", "subagentStop", "workspaceOpen",
    ]

    /// A cheap look at two envelope fields, so the sniff costs a tiny decode
    /// rather than a full parse on every Claude hook.
    static func isCursorEnvelope(_ data: Data) -> Bool {
        struct Sniff: Decodable {
            let cursorVersion: String?
            let hookEventName: String?
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let sniff = try? decoder.decode(Sniff.self, from: data) else { return false }
        if let version = sniff.cursorVersion, !version.isEmpty { return true }
        if let name = sniff.hookEventName, cursorEventNames.contains(name) { return true }
        return false
    }

    private static func result(_ event: HookEvent?) -> Result {
        event.map(Result.event) ?? .undecodable
    }
}
