import Foundation

/// Translates the Codex CLI's `PermissionRequest` tool vocabulary into the
/// canonical (Claude Code) names and input keys that `PermissionMatcher`,
/// `AllowRule` and `ApprovalDetails` already speak.
///
/// Codex's hook payload is Claude-shaped (`tool_name` / `tool_input` /
/// `session_id`) and already says `Bash` for shell commands and `mcp__…` for
/// MCP tools, so the only translation is `apply_patch`: Codex's own matcher
/// aliases it to `Edit` and `Write`, and its `tool_input.command` carries the
/// whole patch rather than a `file_path`.
public enum CodexToolVocabulary {

    /// Canonical tool name. Unknown names pass through unchanged: the matcher's
    /// conservative default arm then forces `.ask`, which is the safe direction.
    public static func canonicalTool(_ raw: String) -> String {
        raw == "apply_patch" ? "Edit" : raw
    }

    /// Canonical input keys. For `apply_patch`, a patch that touches exactly one
    /// file gains a `file_path` so `Edit(<path>)` rules match it and "Always
    /// allow" can persist one; a multi-file patch stays path-less, which keeps
    /// the matcher at `.ask` and persists no rule (over-asking is safe).
    /// Original keys are kept — this only *adds* the canonical spelling.
    public static func canonicalInput(tool raw: String, _ input: [String: Any]) -> [String: Any] {
        guard raw == "apply_patch", input["file_path"] == nil,
              let patch = input["command"] as? String else { return input }
        let paths = patchedFiles(patch)
        guard paths.count == 1, let only = paths.first else { return input }
        var out = input
        out["file_path"] = only
        return out
    }

    /// The distinct file paths named by `*** Add File:` / `*** Update File:` /
    /// `*** Delete File:` headers in an `apply_patch` envelope. `*** Move to:`
    /// is a property of the preceding Update, not a separate file.
    static func patchedFiles(_ patch: String) -> [String] {
        var seen: [String] = []
        for line in patch.split(separator: "\n", omittingEmptySubsequences: true) {
            for header in ["*** Add File: ", "*** Update File: ", "*** Delete File: "]
            where line.hasPrefix(header) {
                let path = line.dropFirst(header.count).trimmingCharacters(in: .whitespaces)
                if !path.isEmpty, !seen.contains(path) { seen.append(path) }
            }
        }
        return seen
    }
}
