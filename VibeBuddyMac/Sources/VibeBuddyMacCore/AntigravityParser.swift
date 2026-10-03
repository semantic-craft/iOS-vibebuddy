import Foundation
import VibeBuddyKit

/// Current Antigravity camelCase hooks carry identity but not the event name.
/// The fail-open wrapper supplies `event`; native transcripts supply recovery.
public enum AntigravityParser {
    public static func parse(_ data: Data, receivedAt: Date) -> HookEvent? {
        guard let envelope = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        let raw = envelope["payload"] as? [String: Any] ?? envelope
        let eventName = envelope["event"] as? String ?? raw["hook_event_name"] as? String ?? ""
        guard let id = raw["conversationId"] as? String ?? raw["session_id"] as? String,
              !id.isEmpty, var kind = mapKind(eventName) else { return nil }
        if eventName == "PreInvocation", (raw["invocationNum"] as? Int ?? 0) > 0 { kind = .sessionMetadataChanged }
        let modern = raw["conversationId"] != nil
        if modern, kind == .stop, raw["fullyIdle"] as? Bool != true { return nil }
        let reason = raw["terminationReason"] as? String ?? ""
        let cancelled = reason == "USER_CANCELED"
        let error = raw["error"] as? String
        let success: Bool? = kind == .stop && modern
            ? (reason == "NO_TOOL_CALL" && (error ?? "").isEmpty) : nil
        let tool = raw["toolCall"] as? [String: Any]
        return HookEvent(kind: kind, sessionID: id, agent: .antigravity,
            cwd: (raw["workspacePaths"] as? [String])?.first ?? raw["cwd"] as? String,
            toolName: tool?["name"] as? String ?? raw["tool_name"] as? String,
            message: cancelled ? "Turn cancelled" : (error?.isEmpty == false ? error : raw["message"] as? String),
            transcriptPath: raw["transcriptPath"] as? String ?? raw["transcript_path"] as? String,
            model: raw["modelName"] as? String,
            toolError: kind == .postToolUse && ((error?.isEmpty == false) || detectToolError(data)),
            timestamp: receivedAt, userStopped: cancelled,
            completionText: success == true ? raw["finalModelOutput"] as? String : nil,
            completionSucceeded: success)
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
        // Only the first invocation starts a turn; PostInvocation is not a
        // terminal event. Native observation covers interactive hook gaps.
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

}
