import Foundation

/// Translates Cursor's tool vocabulary into the canonical (Claude Code) names
/// and input keys that `PermissionMatcher`, `AllowRule`, `ApprovalShortCircuit`
/// and `ApprovalDetails` already speak.
///
/// Applied exactly once, at the hook / `/approval` boundary, so everything
/// downstream stays agent-agnostic — and so an "Always allow" rule written from
/// a Cursor approval (`Bash(git status)`) matches the next Claude call as well.
///
/// The names are the ones Cursor actually writes into its own agent transcripts
/// (`~/.cursor/projects/*/agent-transcripts/*.jsonl`, read on Cursor 3.20):
/// `Shell`, `AwaitShell`, `Read`, `ReadFile`, `Grep`, `Glob`, `Write`,
/// `StrReplace`, `ApplyPatch`, `WebSearch`, `WebFetch`, `Task`, `AskQuestion`,
/// `CallMcpTool`, `GetMcpTools`, `UpdateCurrentStep`, `SetActiveBranch`,
/// `SearchConversations`, `GetDynamicTools`, `CallDynamicTool`.
public enum CursorToolVocabulary {

    /// Cursor's own name for the tool that asks the user a multiple-choice
    /// question. It is Cursor's `AskUserQuestion`: a `preToolUse` gate on it is
    /// a question, not a permission.
    public static let askQuestionTool = "AskQuestion"

    /// Canonical tool name. Unknown names pass through unchanged: the matcher's
    /// conservative default arm then forces `.ask`, which is the safe direction.
    public static func canonicalTool(_ raw: String) -> String {
        switch raw {
        // `AwaitShell` waits on a shell Cursor already started; it carries a
        // `shell_id`, not a command, so it reads as the same Bash family.
        case "Shell", "AwaitShell", "Terminal", "RunTerminalCommand", "run_terminal_cmd":
            return "Bash"
        case "Read", "ReadFile", "read_file":
            return "Read"
        case "StrReplace", "ApplyPatch", "Edit", "SearchReplace", "MultiEdit", "search_replace":
            return "Edit"
        case "Write", "CreateFile", "write_file":
            return "Write"
        case "Grep", "Ripgrep", "rg", "grep_search":
            return "Grep"
        case "Glob", "ListDir", "list_dir", "FileSearch", "file_search":
            return "Glob"
        case "WebSearch", "web_search":
            return "WebSearch"
        case "WebFetch", "web_fetch", "FetchUrl":
            return "WebFetch"
        case "Task", "Subagent", "SpawnSubagent":
            return "Task"
        default:
            // MCP tools can arrive as `server__tool`; Claude's vocabulary — and
            // therefore any rule the user already wrote — is `mcp__server__tool`.
            if raw.contains("__"), !raw.hasPrefix("mcp__") { return "mcp__" + raw }
            return raw
        }
    }

    /// The canonical name for an MCP call Cursor gates through
    /// `beforeMCPExecution`, which names the server separately.
    public static func canonicalMCPTool(server: String?, tool: String) -> String {
        let bare = tool.hasPrefix("mcp__") ? String(tool.dropFirst(5)) : tool
        guard let server = server?.trimmingCharacters(in: .whitespacesAndNewlines), !server.isEmpty,
              !bare.hasPrefix(server + "__") else { return "mcp__" + bare }
        return "mcp__\(server)__\(bare)"
    }

    /// Canonical input keys. Cursor's `Shell` uses `command` and
    /// `working_directory`; `Read`/`Write` use `path`; `StrReplace` uses
    /// `old_str`/`new_str` (and `ApplyPatch` a whole `patch`). Original keys are
    /// kept — this only *adds* the canonical spelling the matcher reads.
    public static func canonicalInput(_ input: [String: Any]) -> [String: Any] {
        var out = input
        for key in ["path", "target_file", "file", "absolute_path", "filePath"] where out["file_path"] == nil {
            if let value = out[key] as? String, !value.isEmpty { out["file_path"] = value }
        }
        if out["old_string"] == nil, let value = out["old_str"] as? String, !value.isEmpty {
            out["old_string"] = value
        }
        if out["new_string"] == nil, let value = out["new_str"] as? String, !value.isEmpty {
            out["new_string"] = value
        }
        if out["content"] == nil, let value = out["contents"] as? String, !value.isEmpty {
            out["content"] = value
        }
        return out
    }

    public static func normalize(
        tool: String, input: [String: Any]
    ) -> (tool: String, input: [String: Any]) {
        (canonicalTool(tool), canonicalInput(input))
    }
}
