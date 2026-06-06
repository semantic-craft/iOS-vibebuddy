import Foundation

/// Maps a coding-agent tool name to a short, human "what it's doing" phrase
/// (English source text; the UI localizes it). Returns `nil` for an unknown or
/// missing tool so the caller falls back to the session summary.
///
/// Matching is case-insensitive and groups the common tools across CLIs (Claude
/// Code, Codex, Qwen, …) by what the user actually cares about — editing,
/// reading, running, searching, browsing, delegating, planning.
public enum ToolActivity {
    public static func phrase(for toolName: String?) -> String? {
        guard let raw = toolName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return nil }
        switch raw.lowercased() {
        case "edit", "write", "multiedit", "notebookedit", "str_replace_editor",
             "apply_patch", "applypatch", "update_file", "create_file", "edit_file":
            return "Editing"
        case "read", "read_file", "readfile", "view", "open", "cat", "notebookread":
            return "Reading"
        case "bash", "shell", "run", "run_command", "runcommand", "execute",
             "exec", "terminal", "run_terminal_cmd":
            return "Running"
        case "grep", "glob", "search", "grep_search", "file_search", "find",
             "codebase_search", "ls", "list":
            return "Searching"
        case "websearch", "web_search", "webfetch", "web_fetch", "fetch", "browser":
            return "Browsing"
        case "task", "agent", "dispatch_agent", "subagent":
            return "Delegating"
        case "todowrite", "todo", "update_plan", "updateplan", "plan":
            return "Planning"
        default:
            return nil
        }
    }
}
