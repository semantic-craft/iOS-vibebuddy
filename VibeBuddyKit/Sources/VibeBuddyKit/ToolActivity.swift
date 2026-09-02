import Foundation

/// Maps a coding-agent tool name to a short, human "what it's doing" phrase
/// (English source text; the UI localizes it). Returns `nil` for an unknown or
/// missing tool so the caller falls back to the session summary.
///
/// Matching is case-insensitive and groups the common tools across CLIs (Claude
/// Code, Codex, Qwen, …) by what the user actually cares about — editing,
/// reading, running, searching, browsing, delegating, planning.
public enum ToolActivity {
    /// One consistent, glanceable state line for every surface that lists a
    /// session. Unlike a prose transcript summary, this always tells the user
    /// whether the agent is active, blocked, or ready.
    public static func label(for session: AgentSession) -> String {
        switch session.status {
        case .needsResponse:
            return session.waitKind == .permission ? "Needs approval" : "Needs input"
        case .working:
            return phrase(for: session.activeTool).map { $0 + "…" } ?? "Working"
        case .done:
            return session.isStuck ? "Stopped with an issue" : "Ready"
        }
    }

    public static func phrase(for toolName: String?) -> String? {
        guard let raw = toolName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return nil }
        let normalized = raw.lowercased()
        let leaf = normalized.split(separator: "/").last.map(String.init) ?? normalized
        switch leaf {
        case "edit", "write", "multiedit", "notebookedit", "str_replace_editor",
             "apply_patch", "applypatch", "update_file", "create_file", "edit_file":
            return "Editing"
        case "read", "read_file", "readfile", "view", "open", "cat", "notebookread",
             "view_image":
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
        case "spawn_agent", "followup_task", "send_message", "list_agents",
             "interrupt_agent":
            return "Coordinating"
        case "wait", "wait_agent", "wait_threads":
            return "Waiting"
        default:
            return nil
        }
    }

    /// Compact parent-row copy: running count, available names/types, and an
    /// unknown/degraded mark. Returns nil when there is no child topology.
    public static func childSummary(for session: AgentSession) -> String? {
        let children = session.childAgents ?? []
        let degraded = session.childTopologyDegraded == true
        if children.isEmpty {
            return degraded ? "Subagents unknown" : nil
        }

        let running = children.filter { $0.status == .running }
        var parts: [String] = []
        if degraded { parts.append("Unknown") }
        if !running.isEmpty {
            parts.append("\(running.count) active")
            let names = running.compactMap { $0.name ?? $0.type }.filter { !$0.isEmpty }
            var seen = Set<String>()
            let unique = names.filter { seen.insert($0).inserted }
            if !unique.isEmpty { parts.append(unique.joined(separator: ", ")) }
            if let activity = running.max(by: { $0.updatedAt < $1.updatedAt })?.lastActivity {
                if let phrase = phrase(for: activity) {
                    parts.append(phrase)
                } else if activity.count <= 40 {
                    parts.append(activity)
                }
            }
        } else if let last = children.max(by: { $0.updatedAt < $1.updatedAt }) {
            let label = last.name ?? last.type ?? "Subagent"
            switch last.status {
            case .idle: parts.append("\(label) idle")
            case .unknown: parts.append("\(label) unknown")
            default: parts.append("\(label) finished")
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
