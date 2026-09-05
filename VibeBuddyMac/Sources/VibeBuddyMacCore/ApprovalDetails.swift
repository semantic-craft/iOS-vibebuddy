import Foundation
import VibeBuddyKit

/// Pulls the rich approval-card fields out of a PreToolUse `tool_input`. Pure
/// and synchronous so the `/approval` route can build a `PendingApproval` before
/// it awaits. Text fields are capped so a huge file can't bloat the snapshot.
public struct ApprovalDetails: Equatable, Sendable {
    public let commandPreview: String   // ≤120 chars, for notifications / fallback
    public let command: String?         // Bash: full command
    public let filePath: String?        // Edit/Write/Read: target path
    public let oldText: String?         // Edit: pre-image
    public let newText: String?         // Edit/Write: post-image / new content

    private static let cap = 6 * 1024

    public static func from(tool: String, input: [String: Any]) -> ApprovalDetails {
        func first(_ keys: String...) -> String? {
            for k in keys { if let v = input[k] as? String, !v.isEmpty { return v } }
            return nil
        }
        func capped(_ s: String?) -> String? {
            guard let s else { return nil }
            return s.count > cap ? String(s.prefix(cap)) : s
        }
        let command  = capped(first("command"))
        let filePath = first("file_path")
        let oldText  = capped(first("old_string", "old_text"))
        let newText  = capped(first("new_string", "new_text", "content", "file_text"))
        // Preview mirrors the old behaviour: Bash → command, file tools → path;
        // `url` closes the WebFetch/web_fetch case, which has neither.
        let previewSource = command ?? filePath ?? newText ?? first("url") ?? ""
        let preview = String(previewSource.prefix(120))
        return ApprovalDetails(commandPreview: preview, command: command,
                               filePath: filePath, oldText: oldText, newText: newText)
    }
}

/// The fields the `/approval` route needs out of a blocking hook payload,
/// decoded per agent. Claude Code (and every Claude-shape CLI) and the Codex CLI
/// send snake_case `tool_name` / `tool_input` / `session_id`; Grok Build sends
/// camelCase `toolName` / `toolInput` / `sessionId` and adds a `permissionMode`.
///
/// Which *event* carried the payload decides both the reply contract and what
/// the request means: a `PermissionRequest` fires only when the agent would
/// prompt (a real wait, answered with `decision.behavior`), while a `PreToolUse`
/// gate fires for every tool call (answered with `permissionDecision`).
///
/// Grok's and Codex's tool vocabularies are normalized here, at the boundary,
/// so the matcher, the allow-store and `ApprovalDetails` all stay agent-agnostic.
public enum ApprovalPayload {
    /// The hook event a gate payload arrived on.
    public enum Event: Equatable, Sendable {
        /// Every tool call, before the agent's own permission check.
        case preToolUse
        /// Only the calls the agent would stop and ask about.
        case permissionRequest
    }

    public struct Call {
        public let tool: String
        public let input: [String: Any]
        public let sessionID: String
        public let event: Event
        /// The agent's permission mode at the time of the call. Claude Code
        /// sends `permission_mode` (`default | plan | acceptEdits | auto |
        /// dontAsk | bypassPermissions`); Grok sends `permissionMode`
        /// (`default | auto | plan | bypassPermissions`). On a `PreToolUse`
        /// gate it drives `ApprovalShortCircuit`; a `PermissionRequest` already
        /// means the agent would ask, so the mode only rides along there.
        /// For Grok outside `bypassPermissions` an `allow` from the phone only
        /// means "the hook didn't block it" — Grok still raises its own local
        /// prompt, which no remote client can answer. A `deny` is authoritative
        /// in every mode, so the phone approval still runs; the mode rides along
        /// on the approval so the UI can say so.
        public let permissionMode: String?
    }

    public static func decode(_ obj: [String: Any], agent: AgentKind) -> Call {
        guard agent == .grok else {
            // Claude-shape envelope. The mode matters only on a `PreToolUse`
            // gate, where it drives the short-circuit; a `PermissionRequest`
            // allow is final on both Claude Code and Codex, so nothing rides
            // along there (the UI would otherwise hedge the way it must for Grok).
            let event: Event = obj["hook_event_name"] as? String == "PermissionRequest"
                ? .permissionRequest : .preToolUse
            let raw = obj["tool_name"] as? String ?? ""
            var input = obj["tool_input"] as? [String: Any] ?? [:]
            var tool = raw
            if agent == .codex {
                tool = CodexToolVocabulary.canonicalTool(raw)
                input = CodexToolVocabulary.canonicalInput(tool: raw, input)
            }
            return Call(tool: tool, input: input,
                        sessionID: obj["session_id"] as? String ?? "",
                        event: event,
                        permissionMode: event == .preToolUse ? nonEmpty(obj["permission_mode"]) : nil)
        }
        // Grok has no PermissionRequest hook; its gate is PreToolUse only.
        let normalized = GrokToolVocabulary.normalize(
            tool: obj["toolName"] as? String ?? "",
            input: obj["toolInput"] as? [String: Any] ?? [:])
        let mode = nonEmpty(obj["permissionMode"])
        return Call(tool: normalized.tool, input: normalized.input,
                    sessionID: obj["sessionId"] as? String ?? "",
                    event: .preToolUse, permissionMode: mode)
    }

    private static func nonEmpty(_ value: Any?) -> String? {
        (value as? String).flatMap { $0.isEmpty ? nil : $0 }
    }
}
