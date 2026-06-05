import Foundation
import VibeBuddyKit

/// Parses Antigravity (`agy`) / Gemini-CLI hook payloads into a normalized
/// `HookEvent`. The envelope is **snake_case Claude-shape** (`hook_event_name`,
/// `session_id`, `cwd`, `tool_name`, `tool_response.error`) — it differs from
/// Claude only in the event *names*. The decoder accepts both name families:
/// Gemini-native (`BeforeAgent`/`BeforeTool`/`AfterTool`/`AfterAgent`) and the
/// Antigravity-2.0 Claude-style spelling (`PreToolUse`/`PostToolUse`/`Stop`/…),
/// so it works whichever the live `agy` build emits. Unknown events and malformed
/// input return `nil` (fail-open).
public enum AntigravityParser {
    public static func parse(_ data: Data, receivedAt: Date) -> HookEvent? {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let raw = try? decoder.decode(RawHook.self, from: data),
              let sessionID = raw.sessionId,
              let kind = mapKind(raw.hookEventName)
        else { return nil }

        return HookEvent(
            kind: kind,
            sessionID: sessionID,
            agent: .antigravity,
            cwd: raw.cwd,
            toolName: raw.toolName,
            message: raw.message,
            transcriptPath: raw.transcriptPath,
            toolError: kind == .postToolUse && detectToolError(data),
            timestamp: receivedAt
        )
    }

    /// A failed `AfterTool`/`PostToolUse`. Gemini signals failure with a present
    /// `tool_response.error`; the Antigravity-2.0/Claude shape uses the usual
    /// `is_error`/`interrupted`/`success:false` markers. Read defensively — the
    /// `tool_response` value varies by tool.
    static func detectToolError(_ data: Data) -> Bool {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let response = obj["tool_response"] as? [String: Any]
        else { return false }
        // Gemini: any non-null `error` means the tool failed, regardless of shape.
        if let error = response["error"], !(error is NSNull) { return true }
        if isTruthy(response["is_error"]) { return true }
        if isTruthy(response["interrupted"]) { return true }
        if let success = response["success"] as? Bool, !success { return true }
        return false
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
        // agy 1.0.5 surface (confirmed live via /hooks): PreToolUse, PostToolUse,
        // PreInvocation, PostInvocation, Stop. agy has no SessionStart, so the
        // first event (PreInvocation, before the turn's first LLM call) creates the
        // session as working. PostInvocation is redundant → ignored.
        case "PreInvocation":                    return .userPromptSubmit
        // Gemini-native + Antigravity-2.0 Claude-style names (kept for tolerance
        // across agy/gemini builds).
        case "SessionStart":                     return .sessionStart
        case "BeforeAgent", "UserPromptSubmit":  return .userPromptSubmit
        case "BeforeTool", "PreToolUse":         return .preToolUse
        case "AfterTool", "PostToolUse":         return .postToolUse
        case "AfterAgent", "Stop":               return .stop
        case "SessionEnd":                       return .sessionEnd
        case "Notification":                     return .notification
        // Ignored: PostInvocation, BeforeModel, AfterModel, PreCompress, …
        default:                                 return nil
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
