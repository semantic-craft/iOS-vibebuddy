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
        // Claude's Notification hook names its own reason. Only some of those
        // reasons are a wait: login confirmations and completed-turn idle
        // reminders do not require an answer.
        if raw.hookEventName == "Notification",
           let type = raw.notificationType, !Self.isWait(notificationType: type) {
            return nil
        }

        // Claude pausing on a usage limit and auto-resuming later is not a
        // wait on the user: it rides as metadata with a line for the row.
        if raw.hookEventName == "Notification",
           let type = raw.notificationType, type.hasPrefix("quota_auto_resume") {
            let line: String
            switch type {
            case "quota_auto_resume_fired": line = "Usage limit reset — resuming"
            case "quota_auto_resume_disabled": line = "Usage limit reached — auto-resume is off"
            default: line = "Usage limit reached — waiting for it to reset"
            }
            return HookEvent(kind: .sessionMetadataChanged, sessionID: sessionID, agent: agent,
                             cwd: raw.cwd, message: line, transcriptPath: raw.transcriptPath,
                             timestamp: receivedAt, permissionModeRaw: raw.permissionMode)
        }

        let message: String?
        if raw.hookEventName == "UserPromptSubmit" {
            message = raw.prompt ?? raw.message
        } else if raw.hookEventName == "PermissionRequest" {
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

        var event = HookEvent(
            kind: agent == .claudeCode && kind == .stop && Self.nonEmpty(raw.agentId) != nil ? .childLifecycle : kind,
            sessionID: sessionID,
            agent: agent,
            cwd: raw.newCwd ?? raw.cwd,
            toolName: toolName,
            message: message,
            waitKind: waitKind(raw),
            transcriptPath: raw.transcriptPath,
            model: raw.toModel ?? raw.model,
            observationSource: agent == .codex ? .hook : nil,
            toolError: kind == .postToolUse && (explicitToolFailure || detectToolError(data)),
            timestamp: receivedAt,
            childID: child.id ?? nestedChildID,
            childKind: child.kind,
            childName: child.name,
            childType: child.type,
            childAction: child.action,
            turnID: agent == .codex ? Self.nonEmpty(raw.turnId) : nil,
            completionText: raw.hookEventName == "Stop" ? raw.lastAssistantMessage : nil,
            completionSucceeded: raw.hookEventName == "Stop",
            permissionModeRaw: raw.permissionMode
        )
        event.startsNewSession = agent == .claudeCode && raw.hookEventName == "SessionStart" && raw.source == "startup"
        if agent == .claudeCode, raw.hookEventName == "Stop", Self.nonEmpty(raw.agentId) == nil {
            event.backgroundWork = backgroundWork(data)
        }
        return event
    }

    /// `background_tasks` and `session_crons` from a `Stop`, read with
    /// `JSONSerialization` so an unexpected shape costs this signal, never the
    /// event. Nil when neither array is present.
    static func backgroundWork(_ data: Data) -> BackgroundWork? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        let tasks = object["background_tasks"] as? [[String: Any]]
        let crons = object["session_crons"] as? [Any]
        guard tasks != nil || crons != nil else { return nil }
        // A cron without `recurring` is read as a loop: the older shape.
        let loops = (crons ?? []).filter { (($0 as? [String: Any])?["recurring"] as? Bool) ?? true }
        var work = BackgroundWork(crons: loops.count)
        for task in tasks ?? [] {
            if let status = (task["status"] as? String)?.lowercased(), finishedTaskStatuses.contains(status) { continue }
            let type = ((task["type"] as? String) ?? "").lowercased()
            if type.contains("subagent") {
                work.subagents += 1
            } else if type.contains("workflow") || type.contains("teammate") {
                work.workflowsOrTeammates += 1
            } else {
                work.otherTasks += 1
            }
        }
        return work
    }

    /// Task statuses that mean the work is over. The docs do not enumerate
    /// `status`, so anything else (including a missing one) counts as running.
    private static let finishedTaskStatuses: Set<String> = [
        "completed", "complete", "done", "finished", "succeeded", "success",
        "failed", "error", "errored", "killed", "stopped", "cancelled", "canceled",
    ]

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

    /// The CLI's own classification of a wait, when it gave one.
    /// `permission_prompt` → permission; `elicitation_dialog`
    /// → question. A `PermissionRequest` hook is a permission by definition and
    /// an `Elicitation` hook a question. Anything else is left for the reducer's
    /// message heuristic.
    static func waitKind(_ raw: RawHook) -> WaitKind? {
        switch raw.hookEventName {
        case "PermissionRequest": return .permission
        case "Elicitation": return .question
        case "Notification":
            switch raw.notificationType {
            case "permission_prompt": return .permission
            case "elicitation_dialog": return .question
            default: return nil
            }
        default: return nil
        }
    }

    /// Whether a named Claude notification describes the agent waiting on you.
    /// Unknown types are treated as waits so a new CLI type is not silently lost.
    static func isWait(notificationType: String) -> Bool {
        notificationType != "auth_success" && notificationType != "idle_prompt"
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
        case "Stop", "StopFailure", "Interrupt":
            guard let id = nonEmpty(raw.agentId) else { return ChildIdentity() }
            return ChildIdentity(id: "subagent:" + id, kind: .subagent,
                name: nonEmpty(raw.agentType), type: nonEmpty(raw.agentType), action: .stopped)
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

    struct RawHook: Decodable {
        let hookEventName: String
        let source: String?
        let sessionId: String?
        let turnId: String?
        let cwd: String?
        let toolName: String?
        let notificationType: String?
        let message: String?
        let prompt: String?
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
        let permissionMode: String?
        let toModel: String?
        let newCwd: String?
    }
}
