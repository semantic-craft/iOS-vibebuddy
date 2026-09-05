import Foundation

/// The calls the phone should never be asked about, decided purely from the
/// tool name and the agent's permission mode at the time of the call.
///
/// The blocking approval hook runs on every PreToolUse regardless of mode, so
/// without this gate a `bypassPermissions` session — one the user explicitly
/// told not to prompt — still raised a phone card and a Mac banner for every
/// tool call. Read-only tools are the same story in every mode: nothing to
/// approve, nothing worth interrupting for.
///
/// Native deny rules are checked before this and still win (ADR 0010); this
/// only decides silent-allow vs ask, never deny.
public enum ApprovalShortCircuit {
    /// Tools that only observe. Never worth a card in any mode. MCP tools
    /// (`mcp__*`) are deliberately absent: their effects are unknowable here.
    public static let readOnlyTools: Set<String> = [
        "Read", "Glob", "Grep", "LS", "WebFetch", "WebSearch",
        "ToolSearch", "TodoWrite", "NotebookRead", "AskUserQuestion",
    ]

    /// Tools `acceptEdits` mode already auto-approves locally.
    public static let editTools: Set<String> = [
        "Edit", "Write", "MultiEdit", "NotebookEdit",
    ]

    /// Whether this call is allowed without asking the phone.
    ///
    /// - `bypassPermissions`: everything.
    /// - `acceptEdits`: read-only tools plus the edit tools.
    /// - `default`, `plan`, `auto`, `dontAsk`, or an absent mode: read-only
    ///   tools only. `auto` and `dontAsk` are grouped with `default` on purpose
    ///   — over-asking is safe, under-asking is not.
    public static func autoAllows(tool: String, permissionMode: String?) -> Bool {
        switch permissionMode {
        case "bypassPermissions":
            return true
        case "acceptEdits":
            return readOnlyTools.contains(tool) || editTools.contains(tool)
        default:
            return readOnlyTools.contains(tool)
        }
    }
}
