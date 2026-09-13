import Foundation
import CoreFoundation

public enum HistoryToolError: Error, LocalizedError {
    case readOnly, noIndex, refreshBusy, invalidArguments(String)
    public var errorDescription: String? {
        switch self {
        case .readOnly: "History repository is read-only."
        case .noIndex: "No usable index. Run vibebuddy-mcp index or open History in the Mac App."
        case .refreshBusy: "another refresh is running"
        case .invalidArguments(let text): text
        }
    }
}

/// The shared read-only tool surface. Formatting and validation have no I/O.
public enum HistoryTools {
    public static func definitions() -> [[String: Any]] {
        [definition("vibebuddy_list_sessions", description: "List indexed local sessions, newest activity first.", properties: [
            "project": ["type": "string"], "agents": ["type": "array", "items": ["type": "string", "enum": ["claude-code", "codex"]]],
            "since": ["type": "string"], "starred": ["type": "boolean"], "limit": ["type": "integer", "minimum": 1, "maximum": 200]
        ]), definition("vibebuddy_list_projects", description: "List projects with indexed sessions, newest activity first.", properties: [
            "since": ["type": "string"], "limit": ["type": "integer", "minimum": 1, "maximum": 200]
        ])]
    }

    private static func definition(_ name: String, description: String, properties: [String: Any]) -> [String: Any] {
        ["name": name, "description": description,
         "inputSchema": ["type": "object", "properties": properties, "additionalProperties": false],
         "annotations": ["readOnlyHint": true, "destructiveHint": false, "idempotentHint": true, "openWorldHint": false]]
    }

    public static func key(_ session: SessionHistorySession) -> String {
        (session.agent == .claude ? "claude-code" : "codex") + ":" + session.nativeSessionID
    }

    public static func call(_ name: String, arguments: [String: Any], snapshot: SessionHistorySnapshot, now: Date = Date()) throws -> String {
        guard let definition = definitions().first(where: { $0["name"] as? String == name }),
              let schema = definition["inputSchema"] as? [String: Any], let properties = schema["properties"] as? [String: Any] else {
            throw HistoryToolError.invalidArguments("Unknown tool: \(name)")
        }
        for (key, value) in arguments {
            guard properties[key] != nil else { throw HistoryToolError.invalidArguments("Unknown argument: \(key)") }
            let valid: Bool
            switch key {
            case "limit":
                if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
                    valid = number.doubleValue.rounded() == number.doubleValue && (1...200).contains(number.doubleValue)
                } else if let string = value as? String, let number = Int(string) { valid = (1...200).contains(number) }
                else { valid = false }
            case "starred": valid = (value as? NSNumber).map { CFGetTypeID($0) == CFBooleanGetTypeID() } ?? false
            case "agents": valid = (value as? [String]).map { $0.allSatisfy { ["claude-code", "codex"].contains($0) } } ?? false
            default: valid = value is String
            }
            guard valid else { throw HistoryToolError.invalidArguments("Invalid argument: \(key)") }
        }
        let limit = (arguments["limit"] as? NSNumber)?.intValue ?? (arguments["limit"] as? String).flatMap(Int.init) ?? 20
        let since = try (arguments["since"] as? String).map { try date($0, now: now) }
        let all = snapshot.sessions.sorted { $0.updatedAt == $1.updatedAt ? key($0) < key($1) : $0.updatedAt > $1.updatedAt }
        let partial = snapshot.pendingSourceCount > 0 ? " Partial index: \(snapshot.pendingSourceCount) source(s) pending; omitted activity may be older or newer." : ""
        let freshness = "Index covers activity up to \(all.first.map { stamp($0.updatedAt) } ?? "unknown (empty index)"). Cached metadata only; newer activity may not be indexed." + partial
        var sessions = all.filter { since == nil || $0.updatedAt >= since! }
        if name == "vibebuddy_list_projects" {
            var seen = Set<String>()
            let rows = sessions.filter { seen.insert($0.projectPath).inserted }.prefix(limit).map { session in
                "| \(cell(session.projectPath)) | \(stamp(session.updatedAt)) | \(sessions.filter { $0.projectPath == session.projectPath }.count) |"
            }
            return (["| Project | Updated | Sessions |", "| --- | --- | ---: |"] + (rows.isEmpty ? ["No projects found."] : rows) + ["", freshness]).joined(separator: "\n")
        }
        if let project = arguments["project"] as? String {
            let known = Set(all.map(\.projectPath)).sorted()
            let matches = project.hasPrefix("/") ? known.filter { $0 == project } : known.filter { URL(fileURLWithPath: $0).lastPathComponent == project }
            guard matches.count == 1 else {
                return (["Project not found or ambiguous. Known projects:"] + known.map { "- " + cell($0) } + ["", freshness]).joined(separator: "\n")
            }
            sessions = sessions.filter { $0.projectPath == matches[0] }
        }
        if let agents = arguments["agents"] as? [String], !agents.isEmpty {
            sessions = sessions.filter { agents.contains($0.agent == .claude ? "claude-code" : "codex") }
        }
        if let starred = arguments["starred"] as? Bool { sessions = sessions.filter { $0.isFavorite == starred } }
        let rows = sessions.prefix(limit).map { s in
            "| \(cell(key(s))) | \(s.agent.displayName) | \(stamp(s.updatedAt)) | \(cell(s.projectPath)) | \(cell(s.title)) | \(s.messageCount) |"
        }
        return (["| Key | Agent | Updated | Project | Title | Messages |", "| --- | --- | --- | --- | --- | ---: |"] + (rows.isEmpty ? ["No sessions found."] : rows) + ["", freshness]).joined(separator: "\n")
    }

    private static func stamp(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }
    private static func cell(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "|", with: "\\|")
            .components(separatedBy: .controlCharacters).joined(separator: " ")
    }
    private static func date(_ text: String, now: Date) throws -> Date {
        if let unit = text.last, unit == "d" || unit == "h", let count = Double(text.dropLast()), count.isFinite, count >= 0 {
            let seconds = count * (unit == "d" ? 86400 : 3600)
            if seconds.isFinite { return now.addingTimeInterval(-seconds) }
        }
        let iso = ISO8601DateFormatter()
        if let result = iso.date(from: text) { return result }
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let result = iso.date(from: text) { return result }
        iso.formatOptions = [.withFullDate]
        if let result = iso.date(from: text), iso.string(from: result) == text { return result }
        throw HistoryToolError.invalidArguments("Invalid since: use 7d, 24h, or an ISO date.")
    }
}

/// Only argv shape is interpreted here; values go unchanged to the tool layer.
public enum HistoryCLI {
    public static let commands = ["sessions": "vibebuddy_list_sessions", "projects": "vibebuddy_list_projects"]
    public static func parse(_ argv: [String]) throws -> (tool: String, arguments: [String: Any]) {
        guard let command = argv.first, let tool = commands[command] else {
            throw HistoryToolError.invalidArguments("Usage: vibebuddy-mcp sessions [--project PATH] [--agent AGENT] [--since DATE] [--starred] [--limit N] | projects [--since DATE] [--limit N] | index [--rebuild]")
        }
        var args: [String: Any] = [:]
        var index = 1
        while index < argv.count {
            let flag = argv[index]
            if flag == "--starred" { args["starred"] = true; index += 1; continue }
            guard ["--project", "--agent", "--since", "--limit"].contains(flag), index + 1 < argv.count else {
                throw HistoryToolError.invalidArguments("Unknown option or missing value: \(flag)")
            }
            let value = argv[index + 1]
            if flag == "--agent" { args["agents"] = (args["agents"] as? [String] ?? []) + [value] }
            else { args[String(flag.dropFirst(2))] = value }
            index += 2
        }
        return (tool, args)
    }
    public static func output(_ text: String) -> String { text.trimmingCharacters(in: .newlines) + "\n" }
}
