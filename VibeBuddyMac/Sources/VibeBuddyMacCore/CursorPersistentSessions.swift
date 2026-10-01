import Foundation

/// Read-only transport discovery. Attached/detached describes tmux clients,
/// never an agent turn, approval, completion or an ACP ownership grant.
public struct CursorPersistentSession: Equatable, Sendable {
    public let sessionName: String
    public let chatID: String
    public let workspace: String
    public let title: String
    public let attached: Bool
}

public enum CursorPersistentSessions {
    public enum Discovery: Equatable, Sendable {
        case available([CursorPersistentSession])
        case unavailable
    }

    public static func discover(executable: URL? = CursorCLI.resolveExecutable()) async -> Discovery {
        guard let executable else { return .unavailable }
        let result = await CursorCLI.run(executable, ["persist", "list"], cwd: nil, timeout: 5)
        guard result.status == 0 else { return .unavailable }
        return parse(result.stdout)
    }

    /// `persist list` has no JSON mode in CLI 2026.09.28-64d2043. Accept its
    /// complete native blocks conservatively; a changed format is unavailable,
    /// not an empty list. Identity comes from Chat ID, never a task title.
    static func parse(_ output: String) -> Discovery {
        let lines = output.components(separatedBy: .newlines)
        if output.trimmingCharacters(in: .whitespacesAndNewlines) == "No Cursor-managed persistent sessions." {
            return .available([])
        }
        guard let header = lines.first,
              let countText = header.split(separator: " ").first,
              let count = Int(countText), count > 0, count <= 1000,
              header == "\(count) persistent \(count == 1 ? "session" : "sessions"):" else { return .unavailable }
        var sessions: [CursorPersistentSession] = []
        var fields: [String: String] = [:]
        var seen = Set<String>()
        func appendBlock() -> Bool {
            guard let title = fields["Task"], let status = fields["Status"],
                  let name = fields["Session"], !name.isEmpty,
                  name.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-")).contains($0) }),
                  let id = fields["Chat ID"], UUID(uuidString: id) != nil,
                  seen.insert(id.lowercased()).inserted,
                  let workspace = fields["Workspace"], workspace.hasPrefix("/"),
                  fields["Attach"] == "agent persist attach \(name)" else { return false }
            let attached: Bool
            if status == "Detached (running in background)" { attached = false }
            else if status.range(of: #"^Attached \([1-9][0-9]* clients?\)$"#, options: .regularExpression) != nil { attached = true }
            else { return false }
            sessions.append(CursorPersistentSession(sessionName: name, chatID: id, workspace: workspace,
                                                    title: title, attached: attached))
            return true
        }
        for raw in lines.dropFirst() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            guard let separator = line.range(of: ": ") else { return .unavailable }
            let key = String(line[..<separator.lowerBound])
            guard ["Task", "Status", "Session", "Chat ID", "Workspace", "Attach"].contains(key) else { return .unavailable }
            if key == "Task", !fields.isEmpty {
                guard appendBlock() else { return .unavailable }
                fields = [:]
            }
            guard fields[key] == nil else { return .unavailable }
            fields[key] = String(line[separator.upperBound...])
        }
        guard !fields.isEmpty, appendBlock(), sessions.count == count else { return .unavailable }
        return .available(sessions)
    }
}
