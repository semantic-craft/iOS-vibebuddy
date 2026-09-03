import Foundation
import VibeBuddyKit

/// Parses Grok Build's hook envelope into a normalized `HookEvent`. Grok's stdin
/// is **camelCase keys with snake_case event values** —
/// `{"hookEventName":"pre_tool_use","sessionId":…,"cwd"/"workspaceRoot":…,
/// "promptId":…,"toolName":…,"toolResult":{"isError":…}}` — distinct from the
/// Claude shape, so it gets its own decoder behind the source-aware
/// `HookDecoder`. Field names follow grok 1.0.13's `HookEventEnvelope`
/// (`xai-grok-hooks/src/event.rs`).
///
/// A payload whose envelope decodes is always *understood*: the events that
/// carry no status change (teardown `stop`, subagent-session events, passive
/// audit records) answer `.ignored`, and only a payload that is not a grok hook
/// envelope at all answers `.undecodable`. Grok fires ignorable events on every
/// session, so conflating the two would report the hook source as an unknown
/// CLI version after each teardown.
///
/// Stateless by design: turn ordering (a `stop_cancelled` that lands after the
/// next prompt) is resolved by the reducer from `HookEvent.turnID`.
public enum GrokParser {
    public static func parse(_ data: Data, receivedAt: Date) -> HookDecoder.Result {
        guard let raw = try? JSONDecoder().decode(RawGrok.self, from: data),
              let event = raw.hookEventName,
              let sessionID = raw.sessionId
        else { return .undecodable }

        // Subagent lifecycle is topology, never parent progress. `subagent_start`
        // fires in the parent; `subagent_stop` fires in the child's own session
        // and carries the same `subagentId`, so the reducer re-attaches it to the
        // parent that already owns that child.
        if event == "subagent_start" || event == "subagent_stop" {
            return .event(childLifecycle(event, raw: raw, sessionID: sessionID,
                                         receivedAt: receivedAt))
        }

        // Every other event that can fire inside a subagent's own session carries
        // `subagentType` there and omits it in the main session (grok's documented
        // "exit 0 when subagentType is present" rule). A child session is not a
        // session we track, and it must never move the parent's status.
        if nonEmpty(raw.subagentType) != nil { return .ignored }

        guard let kind = mapKind(event, raw: raw) else { return .ignored }

        // Grok signals a failed tool either by a dedicated `post_tool_use_failure`
        // event or by `toolResult.isError` inside a `post_tool_use`.
        let isFailureEvent = event == "post_tool_use_failure"
        return .event(HookEvent(
            kind: kind,
            sessionID: sessionID,
            agent: .grok,
            cwd: raw.cwd ?? raw.workspaceRoot,
            toolName: raw.toolName,
            message: message(for: event, raw: raw),
            transcriptPath: nonEmpty(raw.transcriptPath),
            model: nonEmpty(raw.modelId),
            toolError: kind == .postToolUse && (isFailureEvent || detectToolError(data)),
            timestamp: receivedAt,
            turnID: nonEmpty(raw.promptId)
        ))
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

    private static func mapKind(_ name: String, raw: RawGrok) -> HookEvent.Kind? {
        switch name {
        case "session_start":         return .sessionStart
        case "user_prompt_submit":    return .userPromptSubmit
        case "pre_tool_use":          return .preToolUse
        case "post_tool_use",
             "post_tool_use_failure": return .postToolUse
        case "stop":
            // `end_turn` is the genuine turn end. Grok fires `stop` a second time
            // at teardown (`channel_closed`/`shutdown`); `session_end` already
            // reports that, and settling on it would resurrect a closed session.
            switch raw.reason {
            case nil, "end_turn": return .stop
            default:              return nil
            }
        // A failed or cancelled turn is still a turn that ended. `stop_failure`
        // additionally reads as failed through its message (see `message(for:)`).
        case "stop_failure", "stop_cancelled": return .stop
        case "notification":
            switch raw.notificationType {
            // The only grok event that means "a permission UI is actually waiting".
            case "permission_prompt": return .notification
            // Documented idle backstop: fires ~1 min after ANY turn end (including
            // the ends that report no stop at all), and is cancelled by the next
            // prompt. Settling on it is what keeps a missed `stop` from sticking.
            case "idle_prompt":       return .stop
            // `task_complete` reports a BACKGROUND task finishing; it can land
            // mid-turn, so treating it as a turn end would flip a working session
            // to done. The turn end is reported by stop*/idle_prompt.
            default:                  return nil
            }
        case "session_end":           return .sessionEnd
        // `permission_denied` is a passive audit record — the tool call is already
        // over, so it carries no progress. Compaction never changes the three-state.
        default:                      return nil   // permission_denied, pre/post_compact, unknown
        }
    }

    private static func message(for event: String, raw: RawGrok) -> String? {
        switch event {
        case "notification":
            guard raw.notificationType == "permission_prompt" else { return nil }
            // `SessionReducer.waitKind(from:)` reads the wait kind out of this
            // prose, and grok's display text is release-dependent ("Tool
            // permission requested", "Plan approval requested"), so name the
            // permission explicitly when the CLI's own wording doesn't.
            let text = nonEmpty(raw.message) ?? nonEmpty(raw.title)
            guard let text else { return "Permission required" }
            return text.lowercased().contains("permission") ? text : "Permission required: \(text)"
        case "stop_failure":
            // Mirrors Claude's `StopFailure` prose so `FailureHeuristic` marks the
            // session stuck through the same path.
            let kind = nonEmpty(raw.error) ?? "unknown"
            guard let detail = nonEmpty(raw.errorDetails) ?? nonEmpty(raw.lastAssistantMessage) else {
                return "Turn failed: \(kind)"
            }
            return "Turn failed (\(kind)): \(detail)"
        case "stop_cancelled":
            // A cancel is not a failure, so carry only the agent's own words —
            // synthesized prose here would trip the failure heuristic.
            return nonEmpty(raw.lastAssistantMessage)
        case "stop":
            return nonEmpty(raw.lastAssistantMessage)
        default:
            return nonEmpty(raw.message)
        }
    }

    /// `subagentId` is the child's session id on both events, so start (fired in
    /// the parent) and stop (fired in the child) share one stable identity.
    private static func childLifecycle(
        _ event: String,
        raw: RawGrok,
        sessionID: String,
        receivedAt: Date
    ) -> HookEvent {
        let started = event == "subagent_start"
        let type = nonEmpty(raw.subagentType)
        return HookEvent(
            kind: .childLifecycle,
            sessionID: sessionID,
            agent: .grok,
            cwd: raw.cwd ?? raw.workspaceRoot,
            message: nonEmpty(raw.description) ?? nonEmpty(raw.lastAssistantMessage),
            transcriptPath: nonEmpty(raw.transcriptPath),
            timestamp: receivedAt,
            childID: nonEmpty(raw.subagentId).map { "subagent:\($0)" },
            childKind: .subagent,
            childName: type,
            childType: type,
            childAction: started ? .started : .stopped,
            turnID: nonEmpty(raw.promptId)
        )
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    private struct RawGrok: Decodable {
        let hookEventName: String?
        let sessionId: String?
        let cwd: String?
        let workspaceRoot: String?
        let transcriptPath: String?
        let promptId: String?
        let toolName: String?
        let message: String?
        let title: String?
        let notificationType: String?
        let reason: String?
        let error: String?
        let errorDetails: String?
        let lastAssistantMessage: String?
        let modelId: String?
        let subagentId: String?
        let subagentType: String?
        let description: String?
    }
}
