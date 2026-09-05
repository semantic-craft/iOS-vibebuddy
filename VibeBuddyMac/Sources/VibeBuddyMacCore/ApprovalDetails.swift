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

/// The fields the `/approval` route needs out of a blocking PreToolUse payload,
/// decoded per agent. Claude Code (and every Claude-shape CLI) sends snake_case
/// `tool_name` / `tool_input` / `session_id`; Grok Build sends camelCase
/// `toolName` / `toolInput` / `sessionId` and adds a `permissionMode`.
///
/// Grok's tool vocabulary is normalized here, at the boundary, so the matcher,
/// the allow-store and `ApprovalDetails` all stay agent-agnostic.
public enum ApprovalPayload {
    public struct Call {
        public let tool: String
        public let input: [String: Any]
        public let sessionID: String
        /// The agent's permission mode at the time of the call. Claude Code
        /// sends `permission_mode` (`default | plan | acceptEdits | auto |
        /// dontAsk | bypassPermissions`); Grok sends `permissionMode`
        /// (`default | auto | plan | bypassPermissions`). Drives
        /// `ApprovalShortCircuit`: a `bypassPermissions` call is never held.
        /// For Grok outside `bypassPermissions` an `allow` from the phone only
        /// means "the hook didn't block it" — Grok still raises its own local
        /// prompt, which no remote client can answer. A `deny` is authoritative
        /// in every mode, so the phone approval still runs; the mode rides along
        /// on the approval so the UI can say so.
        public let permissionMode: String?
    }

    public static func decode(_ obj: [String: Any], agent: AgentKind) -> Call {
        guard agent == .grok else {
            return Call(tool: obj["tool_name"] as? String ?? "",
                        input: obj["tool_input"] as? [String: Any] ?? [:],
                        sessionID: obj["session_id"] as? String ?? "",
                        permissionMode: nonEmpty(obj["permission_mode"]))
        }
        let normalized = GrokToolVocabulary.normalize(
            tool: obj["toolName"] as? String ?? "",
            input: obj["toolInput"] as? [String: Any] ?? [:])
        let mode = nonEmpty(obj["permissionMode"])
        return Call(tool: normalized.tool, input: normalized.input,
                    sessionID: obj["sessionId"] as? String ?? "",
                    permissionMode: mode)
    }

    private static func nonEmpty(_ value: Any?) -> String? {
        (value as? String).flatMap { $0.isEmpty ? nil : $0 }
    }
}
