import Foundation
import VibeBuddyKit

/// Parses a Cursor hook payload into a normalized `HookEvent`.
///
/// Cursor's envelope is **snake_case keys with camelCase event names**:
/// `{"hook_event_name":"preToolUse","conversation_id":…,"generation_id":…,
/// "workspace_roots":[…],"cwd":…,"tool_name":…,"model":…,"transcript_path":…}`
/// (cursor.com/docs/hooks, and the bundled `~/.cursor/skills-cursor/create-hook`
/// skill). That is close to the Claude shape but the session key and the event
/// names both differ, so it gets its own decoder behind `HookDecoder`.
///
/// Identity is `conversation_id` — the composer id, which is also the name of
/// the conversation's agent transcript directory and its row in Cursor's
/// `composerHeaders` table. Keying on it is what lets the hook, transcript and
/// composer-store sources describe one session instead of three.
///
/// A payload whose envelope decodes is always *understood*: events that carry no
/// status change (`workspaceOpen`, `afterAgentThought`, the Tab hooks) answer
/// `.ignored`, and only a payload that is not a Cursor hook envelope at all
/// answers `.undecodable`. Cursor fires ignorable events routinely, so
/// conflating the two would report the hook source as an unknown CLI version.
public enum CursorParser {

    public static func parse(_ data: Data, receivedAt: Date) -> HookDecoder.Result {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let raw = try? decoder.decode(RawCursor.self, from: data),
              let event = nonEmpty(raw.hookEventName),
              let sessionID = nonEmpty(raw.conversationId) ?? nonEmpty(raw.sessionId)
        else { return .undecodable }

        // Subagent lifecycle is topology, never parent progress.
        if event == "subagentStart" || event == "subagentStop" {
            return .event(childLifecycle(event, raw: raw, sessionID: sessionID, receivedAt: receivedAt))
        }

        guard let kind = mapKind(event) else { return .ignored }

        // `stop` says how the turn ended. `aborted` is Cursor telling us the
        // person stopped it themselves — an ending, not a crash — so it is
        // marked as a user stop rather than left to the failure heuristic,
        // which reads "interrupted" as a break. `error` stays a failure.
        let status = nonEmpty(raw.status)
        let aborted = event == "stop" && status == "aborted"
        let succeeded: Bool? = event == "stop" ? (status == nil || status == "completed") : nil

        let base = HookEvent(
            kind: kind,
            sessionID: sessionID,
            agent: .cursor,
            cwd: nonEmpty(raw.cwd) ?? raw.workspaceRoots?.first(where: { !$0.isEmpty }),
            toolName: toolName(for: event, raw: raw),
            message: message(for: event, raw: raw),
            transcriptPath: nonEmpty(raw.transcriptPath),
            model: nonEmpty(raw.model) ?? nonEmpty(raw.modelId),
            toolError: kind == .postToolUse && isToolFailure(event, raw: raw, data: data),
            timestamp: receivedAt,
            // No `turnID`: Cursor's `generation_id` names one model generation,
            // and a single turn makes several, so pairing a stop with the
            // prompt's id would drop the ending as stale. Cursor stops settle
            // unconditionally, as Claude's and Codex's do.
            enrichment: enrichment(for: event, raw: raw),
            completionText: nil,
            completionSucceeded: succeeded
        )
        return .event(aborted ? base.markingUserStop() : base)
    }

    // MARK: - Event mapping

    /// Cursor's agent hooks, mapped onto vibebuddy's normalized lifecycle.
    /// Every gate event (`beforeShellExecution`, `beforeMCPExecution`,
    /// `beforeReadFile`) is a pre-tool signal as well as a permission gate: the
    /// `/approval` route ingests the same payload, so a session moves to
    /// `working` whether or not the status forwarders are installed.
    static func mapKind(_ name: String) -> HookEvent.Kind? {
        switch name {
        case "sessionStart": return .sessionStart
        case "beforeSubmitPrompt": return .userPromptSubmit
        case "preToolUse", "beforeShellExecution", "beforeMCPExecution",
             "beforeReadFile", "preCompact": return .preToolUse
        case "postToolUse", "postToolUseFailure", "afterShellExecution",
             "afterMCPExecution", "afterFileEdit": return .postToolUse
        case "afterAgentResponse": return .sessionMetadataChanged
        case "stop": return .stop
        case "sessionEnd": return .sessionEnd
        // Thought deltas, Tab completions and workspace open are understood and
        // deliberately dropped: they say nothing about the three states and
        // would only churn the snapshot.
        case "afterAgentThought", "workspaceOpen",
             "beforeTabFileRead", "afterTabFileEdit": return nil
        default: return nil
        }
    }

    /// The row's activity line. Cursor's shell and MCP gates name no tool, so
    /// they borrow the canonical name the vocabulary gives them.
    static func toolName(for event: String, raw: RawCursor) -> String? {
        switch event {
        case "beforeShellExecution", "afterShellExecution":
            return "Bash"
        case "beforeMCPExecution", "afterMCPExecution":
            return CursorToolVocabulary.canonicalMCPTool(server: raw.mcpServerName,
                                                         tool: nonEmpty(raw.toolName) ?? "tool")
        case "beforeReadFile":
            return "Read"
        case "afterFileEdit":
            return "Edit"
        case "preCompact":
            return "Context compaction"
        default:
            return nonEmpty(raw.toolName).map(CursorToolVocabulary.canonicalTool)
        }
    }

    static func message(for event: String, raw: RawCursor) -> String? {
        switch event {
        case "beforeSubmitPrompt":
            return nonEmpty(raw.prompt).map { String($0.prefix(220)) }
        case "afterAgentResponse":
            return nonEmpty(raw.text).map { String($0.prefix(220)) }
        case "postToolUseFailure":
            return nonEmpty(raw.errorMessage) ?? nonEmpty(raw.failureType)
        case "stop":
            switch nonEmpty(raw.status) {
            case "error": return "Turn failed"
            case "aborted": return "Turn stopped"
            default: return nil
            }
        case "sessionEnd":
            return nonEmpty(raw.errorMessage) ?? nonEmpty(raw.reason)
        default:
            return nil
        }
    }

    /// Facts a hook carried alongside the event. Only `preCompact` reports
    /// context size, and it reports the real window rather than a model-table
    /// guess, so it is worth keeping.
    static func enrichment(for event: String, raw: RawCursor) -> TranscriptInfo? {
        guard event == "preCompact" else { return nil }
        let used = raw.contextTokens
        let window = raw.contextWindowSize
        guard used != nil || window != nil else { return nil }
        return TranscriptInfo(contextTokens: used, contextWindow: window)
    }

    /// Did this tool call fail? `postToolUseFailure` is explicit; a plain
    /// `postToolUse` can still carry an error marker inside `tool_output`, and an
    /// `afterShellExecution` can report a non-zero exit. Read `tool_output`
    /// defensively — it is a string for some tools and an object for others.
    static func isToolFailure(_ event: String, raw: RawCursor, data: Data) -> Bool {
        if event == "postToolUseFailure" { return true }
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return false }
        if let output = obj["tool_output"] as? [String: Any] {
            if isTruthy(output["is_error"]) { return true }
            if isTruthy(output["error"]) { return true }
            if let success = output["success"] as? Bool, !success { return true }
        }
        if let code = obj["exit_code"] as? NSNumber, code.intValue != 0 { return true }
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

    /// `subagentStart` / `subagentStop` describe a child of this conversation.
    /// `subagentStop` carries no `subagent_id`, only the type, so the identity
    /// falls back to the type — enough for the reducer to pair a stop with the
    /// start that named the same type, and flagged as degraded when it cannot.
    static func childLifecycle(_ event: String, raw: RawCursor, sessionID: String,
                               receivedAt: Date) -> HookEvent {
        let type = nonEmpty(raw.subagentType)
        let id = nonEmpty(raw.subagentId).map { "subagent:\($0)" }
            ?? type.map { "subagent:\($0)" }
        return HookEvent(
            kind: .childLifecycle,
            sessionID: nonEmpty(raw.parentConversationId) ?? sessionID,
            agent: .cursor,
            cwd: nonEmpty(raw.cwd) ?? raw.workspaceRoots?.first(where: { !$0.isEmpty }),
            message: nonEmpty(raw.summary) ?? nonEmpty(raw.description) ?? nonEmpty(raw.task),
            transcriptPath: nonEmpty(raw.agentTranscriptPath) ?? nonEmpty(raw.transcriptPath),
            timestamp: receivedAt,
            childID: id,
            childKind: .subagent,
            childName: type,
            childType: type,
            childAction: event == "subagentStart" ? .started : .stopped)
    }

    static func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    /// The union of the fields Cursor's agent hooks send (cursor.com/docs/hooks).
    /// Everything is optional: one event's fields are another's absence, and a
    /// Cursor release that adds a field must not stop the envelope decoding.
    struct RawCursor: Decodable {
        // Base, on every hook
        let hookEventName: String?
        let conversationId: String?
        let generationId: String?
        let model: String?
        let modelId: String?
        let transcriptPath: String?
        let workspaceRoots: [String]?
        let cursorVersion: String?
        // sessionStart / sessionEnd
        let sessionId: String?
        let reason: String?
        let finalStatus: String?
        let isBackgroundAgent: Bool?
        let composerMode: String?
        // tool events
        let cwd: String?
        let toolName: String?
        let toolUseId: String?
        let errorMessage: String?
        let failureType: String?
        let isInterrupt: Bool?
        // shell / MCP / file gates
        let command: String?
        let filePath: String?
        let mcpServerName: String?
        // prompt / response
        let prompt: String?
        let text: String?
        // stop
        let status: String?
        let loopCount: Int?
        // preCompact
        let trigger: String?
        let contextTokens: Int?
        let contextWindowSize: Int?
        // subagents
        let subagentId: String?
        let subagentType: String?
        let parentConversationId: String?
        let task: String?
        let description: String?
        let summary: String?
        let agentTranscriptPath: String?
    }
}
