import Foundation

/// Translates Grok Build's tool vocabulary into the canonical (Claude Code)
/// names and input keys that `PermissionMatcher`, `AllowRule` and
/// `ApprovalDetails` already speak.
///
/// Applied exactly once, at the `/approval` route boundary, so everything
/// downstream stays agent-agnostic — and so an "Always allow" rule written from
/// a Grok approval (`Bash(git status)`) matches the next Grok call as well as a
/// Claude one. It is also what makes Grok's own Claude-style rule strings
/// (`Bash(npm *)` in `~/.grok/config.toml`) apply to `run_terminal_command`,
/// mirroring how Grok itself aliases matchers.
public enum GrokToolVocabulary {

    /// Canonical tool name for a Grok tool name. Unknown names pass through
    /// unchanged: the matcher's conservative default arm then forces `.ask`,
    /// which is the safe direction.
    public static func canonicalTool(_ raw: String) -> String {
        let name = bareName(raw)
        switch name {
        // `run_terminal_cmd` is the older recording spelling; `bash`/`shell` are
        // the aliases Grok's own permission hub accepts.
        case "run_terminal_command", "run_terminal_cmd", "bash", "shell":
            return "Bash"
        case "read_file", "hashline_read":
            return "Read"
        case "search_replace", "hashline_edit", "edit", "apply_patch", "str_replace":
            return "Edit"
        case "write", "write_file", "create_file":
            return "Write"
        case "grep", "hashline_grep":
            return "Grep"
        case "list_dir", "list_directory":
            return "Glob"
        case "web_search":
            return "WebSearch"
        case "web_fetch":
            return "WebFetch"
        case "spawn_subagent", "task":
            return "Task"
        default:
            // MCP tools reach the hook as `server__tool`; Claude's vocabulary —
            // and therefore any rule the user already wrote — is `mcp__server__tool`.
            if name.contains("__"), !name.hasPrefix("mcp__") { return "mcp__" + name }
            return name
        }
    }

    /// Canonical input keys. Grok's `search_replace` and `write` already use
    /// `file_path` / `old_string` / `new_string` / `content` (verified against
    /// `tool_call.rawInput` in real `updates.jsonl` records), so the only
    /// divergence is the read/list target: `target_file` and `target_directory`.
    /// Original keys are kept — this only *adds* the canonical spelling.
    public static func canonicalInput(_ input: [String: Any]) -> [String: Any] {
        var out = input
        for key in ["target_file", "target_directory"] where out["file_path"] == nil {
            if let value = out[key] as? String, !value.isEmpty { out["file_path"] = value }
        }
        return out
    }

    public static func normalize(
        tool: String, input: [String: Any]
    ) -> (tool: String, input: [String: Any]) {
        (canonicalTool(tool), canonicalInput(input))
    }

    /// `GrokBuild:read_file` → `read_file`. Grok qualifies builtin tool ids with
    /// a provider prefix in some surfaces; the hook payload usually doesn't, but
    /// stripping it costs nothing and stops a qualified name falling through.
    private static func bareName(_ raw: String) -> String {
        guard let colon = raw.lastIndex(of: ":") else { return raw }
        return String(raw[raw.index(after: colon)...])
    }
}
