import Foundation

/// The App's Copy buttons and CLI setup print these exact same snippets.
public struct HistoryConnectionSetup: Sendable {
    public let executablePath: String

    public init(executablePath: String) { self.executablePath = executablePath }

    public enum Client: String, CaseIterable, Sendable {
        case claude, codex, cursor
        public var title: String {
            switch self { case .claude: "Claude Code"; case .codex: "Codex"; case .cursor: "Cursor" }
        }
        public var instruction: String {
            switch self {
            case .claude: "Run in your project, then approve vibebuddy in Claude Code."
            case .codex: "Merge into ~/.codex/config.toml, then restart your Codex session."
            case .cursor: "Merge into ~/.cursor/mcp.json, then reload Cursor and enable vibebuddy."
            }
        }
    }

    public func configuration(for client: Client) -> String {
        switch client {
        case .claude:
            return "claude mcp add --scope project --transport stdio vibebuddy -- " + Self.shellQuote(executablePath)
        case .codex:
            return "[mcp_servers.vibebuddy]\ncommand = \(Self.stringLiteral(executablePath))\nargs = []"
        case .cursor:
            return """
            {
              "mcpServers": {
                "vibebuddy": {
                  "type": "stdio",
                  "command": \(Self.stringLiteral(executablePath)),
                  "args": []
                }
              }
            }
            """
        }
    }

    public var agentRule: String {
        """
        Before resuming work, read the ticket and its newest handoff under .scratch/<feature>/handoffs/.
        Use vibebuddy_list_sessions for this checkout, then vibebuddy_get_summary or vibebuddy_get_session for missing context.
        Use vibebuddy_search to locate readable history and follow its exact session references.
        These tools only read; summaries may be stale or absent, and source coverage differs (Grok Build has list/title only).
        vibebuddy_live_status is an optional collaboration hint; unknown status does not block history access.
        A handoff's Source session must be the writer's own native session key, or unknown; never guess the newest session.
        """
    }

    public func instructions(indexAvailable: Bool) -> String {
        var sections = ["vibebuddy MCP / CLI", "Executable: " + executablePath]
        if !indexAvailable {
            sections.append("Note: No usable History index. Open History in the Mac App, or explicitly run \(Self.shellQuote(executablePath)) index. Setup does not create an index.")
        }
        for client in Client.allCases {
            sections.append(client.title + "\n" + client.instruction + "\n\n" + configuration(for: client))
        }
        sections.append("Optional AGENTS.md rule\n\n" + agentRule)
        sections.append("Queries: sessions, projects, search, show, summary, status. No arguments starts stdio MCP. Only index [--rebuild] maintains the local index; setup only prints these instructions.")
        return sections.joined(separator: "\n\n")
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    /// JSON and TOML basic strings share these escapes. Do not emit JSON's optional \/ escape.
    private static func stringLiteral(_ value: String) -> String {
        let body = value.unicodeScalars.map { scalar -> String in
            switch scalar.value {
            case 34: return "\\\""
            case 92: return "\\\\"
            case 0...31, 127: return String(format: "\\u%04X", scalar.value)
            default: return String(scalar)
            }
        }.joined()
        return "\"" + body + "\""
    }
}
