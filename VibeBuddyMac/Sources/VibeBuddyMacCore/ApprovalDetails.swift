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
/// decoded per agent. Claude Code (and every Claude-shape CLI) sends snake_case
/// `tool_name` / `tool_input` / `session_id` on `PreToolUse`; the Codex CLI
/// sends the same snake_case shape on `PermissionRequest`; Grok Build sends
/// camelCase `toolName` / `toolInput` / `sessionId` and adds a `permissionMode`.
///
/// Grok's and Codex's tool vocabularies are normalized here, at the boundary,
/// so the matcher, the allow-store and `ApprovalDetails` all stay agent-agnostic.
public enum ApprovalPayload {
    public struct Call {
        public let tool: String
        public let input: [String: Any]
        public let sessionID: String
        /// Grok only: `default | auto | plan | bypassPermissions` at the time of
        /// the call. Outside `bypassPermissions` an `allow` from the phone only
        /// means "the hook didn't block it" — Grok still raises its own local
        /// prompt, which no remote client can answer. A `deny` is authoritative
        /// in every mode, so the phone approval still runs; the mode rides along
        /// on the approval so the UI can say so.
        public let permissionMode: String?
    }

    public static func decode(_ obj: [String: Any], agent: AgentKind) -> Call {
        if agent == .codex {
            // Codex only fires `PermissionRequest` when it would prompt, and a
            // hook `allow` is final there — so no `permissionMode` rides along
            // (the UI would otherwise hedge the way it must for Grok).
            let raw = obj["tool_name"] as? String ?? ""
            let input = obj["tool_input"] as? [String: Any] ?? [:]
            return Call(tool: CodexToolVocabulary.canonicalTool(raw),
                        input: CodexToolVocabulary.canonicalInput(tool: raw, input),
                        sessionID: obj["session_id"] as? String ?? "",
                        permissionMode: nil)
        }
        guard agent == .grok else {
            return Call(tool: obj["tool_name"] as? String ?? "",
                        input: obj["tool_input"] as? [String: Any] ?? [:],
                        sessionID: obj["session_id"] as? String ?? "",
                        permissionMode: nil)
        }
        let normalized = GrokToolVocabulary.normalize(
            tool: obj["toolName"] as? String ?? "",
            input: obj["toolInput"] as? [String: Any] ?? [:])
        let mode = (obj["permissionMode"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return Call(tool: normalized.tool, input: normalized.input,
                    sessionID: obj["sessionId"] as? String ?? "",
                    permissionMode: mode)
    }
}
