import Foundation

public enum HistoryToolError: Error, LocalizedError {
    case invalidArguments(String), invalidValue(String), executionFailed(String)
    public var errorDescription: String? {
        switch self {
        case .invalidArguments(let text), .invalidValue(let text), .executionFailed(let text): text
        }
    }
}

/// The shared read-only tool surface: one live transcript, live status and
/// handoff facts. There is no history index or archive behind any of them.
public enum HistoryTools {
    public static func definitions() -> [[String: Any]] {
        [definition("vibebuddy_get_session", description: "Read one session's local transcript by native key or reference, straight from the agent's own file; sequence positions are stable for its source revision.", properties: [
            "key": ["type": "string"], "from_seq": ["type": "integer", "minimum": 1],
            "max_messages": ["type": "integer", "minimum": 1, "maximum": 200],
            "tools": ["type": "boolean"], "thinking": ["type": "boolean"]
        ], required: ["key"])] + [HistoryLiveStatus.definition, HandoffFacts.definition]
    }

    private static func definition(_ name: String, description: String, properties: [String: Any], required: [String] = []) -> [String: Any] {
        ["name": name, "description": description,
         "inputSchema": ["type": "object", "properties": properties, "required": required, "additionalProperties": false],
         "annotations": ["readOnlyHint": true, "destructiveHint": false, "idempotentHint": true, "openWorldHint": false]]
    }
}

/// Only argv shape is interpreted here; values go unchanged to the tool layer.
public enum HistoryCLI {
    public static let commands = ["show": "vibebuddy_get_session", "status": "vibebuddy_live_status", "facts": HandoffFacts.toolName]
    public static func parse(_ argv: [String]) throws -> (tool: String, arguments: [String: Any]) {
        if argv.first == "call" {
            guard argv.count == 3, let data = argv[2].data(using: .utf8),
                  let arguments = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                throw HistoryToolError.invalidArguments("Usage: vibebuddy-mcp call <tool> '<JSON object>'")
            }
            return (argv[1], arguments)
        }
        guard let command = argv.first, let tool = commands[command] else {
            throw HistoryToolError.invalidArguments("Usage: vibebuddy-mcp facts KEY|REF [--commands N] [--cwd PATH] | show KEY|REF [--from-seq N] [--max-messages N] [--tools] [--thinking] | status [--project PATH] [--exclude-session ID] | setup | call <tool> '<JSON object>'; no arguments starts stdio MCP")
        }
        var args: [String: Any] = [:]
        var index = 1
        if ["show", "facts"].contains(command) {
            guard argv.count > 1, !argv[1].hasPrefix("--") else { throw HistoryToolError.invalidArguments("\(command) requires a positional key or reference.") }
            args["key"] = argv[1]; index = 2
        }
        while index < argv.count {
            let flag = argv[index]
            if ["--tools", "--thinking"].contains(flag) { args[String(flag.dropFirst(2))] = true; index += 1; continue }
            guard ["--project", "--from-seq", "--max-messages", "--exclude-session", "--commands", "--cwd"].contains(flag), index + 1 < argv.count else {
                throw HistoryToolError.invalidArguments("Unknown option or missing value: \(flag)")
            }
            args[String(flag.dropFirst(2)).replacingOccurrences(of: "-", with: "_")] = argv[index + 1]
            index += 2
        }
        return (tool, args)
    }
    public static func output(_ text: String) -> String { text.trimmingCharacters(in: .newlines) + "\n" }
}
