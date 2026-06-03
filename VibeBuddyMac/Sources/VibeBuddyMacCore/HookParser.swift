import Foundation
import VibeBuddyKit

/// Parses a raw Claude Code hook payload (the JSON the hook command forwards on
/// stdin) into a normalized `HookEvent`. Unknown event types and malformed
/// input return `nil` so the server can ignore them without failing.
public enum HookParser {

    public static func parse(
        _ data: Data,
        agent: AgentKind = .claudeCode,
        receivedAt: Date
    ) -> HookEvent? {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let raw = try? decoder.decode(RawHook.self, from: data),
              let sessionID = raw.sessionId,
              let kind = mapKind(raw.hookEventName)
        else { return nil }

        return HookEvent(
            kind: kind,
            sessionID: sessionID,
            agent: agent,
            cwd: raw.cwd,
            toolName: raw.toolName,
            message: raw.message,
            timestamp: receivedAt
        )
    }

    private static func mapKind(_ name: String) -> HookEvent.Kind? {
        switch name {
        case "SessionStart": return .sessionStart
        case "UserPromptSubmit": return .userPromptSubmit
        case "PreToolUse": return .preToolUse
        case "PostToolUse": return .postToolUse
        case "Notification": return .notification
        case "Stop": return .stop
        default: return nil
        }
    }

    private struct RawHook: Decodable {
        let hookEventName: String
        let sessionId: String?
        let cwd: String?
        let toolName: String?
        let message: String?
    }
}
