import Foundation

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
        // Preview mirrors the old behaviour: Bash → command, file tools → path.
        let previewSource = command ?? filePath ?? newText ?? ""
        let preview = String(previewSource.prefix(120))
        return ApprovalDetails(commandPreview: preview, command: command,
                               filePath: filePath, oldText: oldText, newText: newText)
    }
}
