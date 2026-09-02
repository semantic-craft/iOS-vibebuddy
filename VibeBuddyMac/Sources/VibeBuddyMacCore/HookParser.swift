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

        let message: String?
        if raw.hookEventName == "PermissionRequest" {
            message = raw.toolName.map { "Permission required for \($0)" } ?? "Permission required"
        } else if raw.hookEventName == "PermissionDenied" {
            message = raw.toolName.map { "Permission denied for \($0)" } ?? "Permission denied"
        } else if raw.hookEventName == "StopFailure" {
            message = raw.error ?? "Turn failed"
        } else if raw.hookEventName == "Interrupt" {
            message = "Turn interrupted"
        } else if raw.hookEventName == "Elicitation" {
            message = raw.message ?? "Waiting for your input"
        } else {
            message = raw.message ?? raw.error ?? raw.lastAssistantMessage
        }

        let toolName: String?
        switch raw.hookEventName {
        case "PreCompact", "PostCompact":
            toolName = "Context compaction"
        case "Elicitation", "ElicitationResult":
            toolName = "MCP elicitation"
        case "PostToolBatch":
            toolName = "Tool batch"
        default:
            toolName = raw.toolName
        }

        let explicitToolFailure = raw.hookEventName == "PostToolUseFailure"
            || raw.hookEventName == "PermissionDenied"
        let child = childIdentity(raw)
        let nestedChildID = (kind == .preToolUse || kind == .postToolUse)
            ? Self.nonEmpty(raw.agentId).map { "subagent:\($0)" }
            : nil

        return HookEvent(
            kind: kind,
            sessionID: sessionID,
            agent: agent,
            cwd: raw.newCwd ?? raw.cwd,
            toolName: toolName,
            message: message,
            transcriptPath: raw.transcriptPath,
            model: raw.toModel ?? raw.model,
            toolError: kind == .postToolUse && (explicitToolFailure || detectToolError(data)),
            timestamp: receivedAt,
            childID: child.id ?? nestedChildID,
            childKind: child.kind,
            childName: child.name,
            childType: child.type,
            childAction: child.action
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
        case "PostToolUseFailure", "PermissionDenied", "PostToolBatch",
             "ElicitationResult": return .postToolUse
        case "PreCompact": return .preToolUse
        case "PostCompact": return .postToolUse
        case "SubagentStart", "SubagentStop", "TaskCreated", "TaskCompleted",
             "TeammateIdle": return .childLifecycle
        case "Notification", "PermissionRequest", "Elicitation": return .notification
        case "Stop", "StopFailure", "Interrupt": return .stop
        case "SessionEnd": return .sessionEnd
        case "PostModelSwitch", "CwdChanged": return .sessionMetadataChanged
        default: return nil
        }
    }

    private struct ChildIdentity {
        var id: String? = nil
        var kind: ChildAgentKind? = nil
        var name: String? = nil
        var type: String? = nil
        var action: HookEvent.ChildLifecycleAction? = nil
    }

    private static func childIdentity(_ raw: RawHook) -> ChildIdentity {
        switch raw.hookEventName {
        case "SubagentStart":
            return ChildIdentity(
                id: nonEmpty(raw.agentId).map { "subagent:\($0)" },
                kind: .subagent,
                name: nonEmpty(raw.agentType),
                type: nonEmpty(raw.agentType),
                action: .started)
        case "SubagentStop":
            return ChildIdentity(
                id: nonEmpty(raw.agentId).map { "subagent:\($0)" },
                kind: .subagent,
                name: nonEmpty(raw.agentType),
                type: nonEmpty(raw.agentType),
                action: .stopped)
        case "TaskCreated":
            return ChildIdentity(
                id: nonEmpty(raw.taskId).map { "task:\($0)" },
                kind: .task,
                name: nonEmpty(raw.teammateName) ?? nonEmpty(raw.taskSubject),
                type: nonEmpty(raw.teammateName),
                action: .started)
        case "TaskCompleted":
            return ChildIdentity(
                id: nonEmpty(raw.taskId).map { "task:\($0)" },
                kind: .task,
                name: nonEmpty(raw.teammateName) ?? nonEmpty(raw.taskSubject),
                type: nonEmpty(raw.teammateName),
                action: .stopped)
        case "TeammateIdle":
            guard let name = nonEmpty(raw.teammateName) else {
                return ChildIdentity(kind: .teammate, type: nonEmpty(raw.teamName), action: .idled)
            }
            let id = nonEmpty(raw.teamName).map { "teammate:\($0)/\(name)" } ?? "teammate:\(name)"
            return ChildIdentity(id: id, kind: .teammate, name: name, type: nonEmpty(raw.teamName), action: .idled)
        default:
            return ChildIdentity()
        }
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    private struct RawHook: Decodable {
        let hookEventName: String
        let sessionId: String?
        let cwd: String?
        let toolName: String?
        let message: String?
        let error: String?
        let lastAssistantMessage: String?
        let transcriptPath: String?
        let agentId: String?
        let agentType: String?
        let taskId: String?
        let taskSubject: String?
        let teammateName: String?
        let teamName: String?
        let model: String?
        let toModel: String?
        let newCwd: String?
    }
}
