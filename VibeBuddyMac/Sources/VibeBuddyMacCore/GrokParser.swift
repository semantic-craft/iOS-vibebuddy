import Foundation
import VibeBuddyKit

/// Parses Grok Build's hook envelope into a normalized `HookEvent`. Grok's stdin
/// is **camelCase keys with snake_case event values** —
/// `{"hookEventName":"pre_tool_use","sessionId":…,"cwd"/"workspaceRoot":…,
/// "toolName":…,"toolResult":{"isError":…}}` — distinct from the Claude shape, so
/// it gets its own decoder behind the source-aware `HookDecoder`. Unknown events
/// and malformed input return `nil` so the daemon ignores them (fail-open).
public enum GrokParser {
    public static func parse(_ data: Data, receivedAt: Date) -> HookEvent? {
        guard let raw = try? JSONDecoder().decode(RawGrok.self, from: data),
              let event = raw.hookEventName,
              let sessionID = raw.sessionId,
              let kind = mapKind(event)
        else { return nil }

        // Grok signals a failed tool either by a dedicated `post_tool_use_failure`
        // event or by `toolResult.isError` inside a `post_tool_use`.
        let isFailureEvent = event == "post_tool_use_failure"
        return HookEvent(
            kind: kind,
            sessionID: sessionID,
            agent: .grok,
            cwd: raw.cwd ?? raw.workspaceRoot,
            toolName: raw.toolName,
            message: raw.message,
            toolError: kind == .postToolUse && (isFailureEvent || detectToolError(data)),
            timestamp: receivedAt
        )
    }

    /// Read `toolResult.isError` defensively with `JSONSerialization` (not the
    /// strict decoder): `toolResult` may be a string, object, or array depending
    /// on the tool, so we only look for an error marker and ignore the rest.
    static func detectToolError(_ data: Data) -> Bool {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return false }
        if let result = obj["toolResult"] as? [String: Any] {
            if isTruthy(result["isError"]) { return true }
            if isTruthy(result["error"]) { return true }
        }
        return isTruthy(obj["isError"])
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
        case "session_start":         return .sessionStart
        case "user_prompt_submit":    return .userPromptSubmit
        case "pre_tool_use":          return .preToolUse
        case "post_tool_use",
             "post_tool_use_failure": return .postToolUse
        case "stop":                  return .stop
        case "session_end":           return .sessionEnd
        // Grok's `notification` is hook-execution telemetry (it echoes which hooks
        // ran), NOT a user-attention request like Claude's — so ignore it; mapping
        // it to needsResponse wrongly overrides `stop`→done. Grok approvals come
        // through the blocking `pre_tool_use` path instead.
        default:                      return nil   // notification, pre_compact, subagent_*, unknown
        }
    }

    private struct RawGrok: Decodable {
        let hookEventName: String?
        let sessionId: String?
        let cwd: String?
        let workspaceRoot: String?
        let toolName: String?
        let message: String?
    }
}
