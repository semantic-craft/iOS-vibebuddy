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
            transcriptPath: raw.transcriptPath,
            toolError: kind == .postToolUse && detectToolError(data),
            timestamp: receivedAt
        )
    }

    /// Did this tool result report a failure? Read defensively with
    /// `JSONSerialization` (not the strict decoder) because `tool_response` can
    /// be a string, object, or array depending on the tool — we only look for an
    /// error marker and ignore everything else.
    static func detectToolError(_ data: Data) -> Bool {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return false }
        if let response = obj["tool_response"] as? [String: Any] {
            if isTruthy(response["is_error"]) { return true }
            if isTruthy(response["interrupted"]) { return true }
            if isTruthy(response["error"]) { return true }
            if let success = response["success"] as? Bool, !success { return true }
        }
        // Some agents put the error at the top level instead.
        return isTruthy(obj["error"])
    }

    private static func isTruthy(_ value: Any?) -> Bool {
        switch value {
        case let b as Bool: return b
        case let s as String: return !s.isEmpty
        case let n as NSNumber: return n.boolValue
        default: return false
        }
    }

    private static func mapKind(_ name: String) -> HookEvent.Kind? {
        switch name {
        case "SessionStart": return .sessionStart
        case "UserPromptSubmit": return .userPromptSubmit
        case "PreToolUse": return .preToolUse
        case "PostToolUse": return .postToolUse
        case "Notification": return .notification
        case "Stop": return .stop
        case "SessionEnd": return .sessionEnd
        default: return nil
        }
    }

    private struct RawHook: Decodable {
        let hookEventName: String
        let sessionId: String?
        let cwd: String?
        let toolName: String?
        let message: String?
        let transcriptPath: String?
    }
}
