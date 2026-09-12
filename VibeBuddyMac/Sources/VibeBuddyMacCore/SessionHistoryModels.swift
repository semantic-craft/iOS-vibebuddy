import Foundation

public enum SessionHistoryAgent: String, Codable, Sendable, CaseIterable {
    case claude, codex
    public var displayName: String { self == .claude ? "Claude Code" : "Codex" }
}
public enum SessionHistoryRole: String, Codable, Sendable { case user, assistant, tool, system }
public struct SessionHistoryMessage: Identifiable, Codable, Sendable, Equatable {
    public var id: String
    public var role: SessionHistoryRole
    public var text: String
    public var timestamp: Date?
    public var toolName: String?
    public init(id: String, role: SessionHistoryRole, text: String, timestamp: Date? = nil, toolName: String? = nil) {
        self.id = id; self.role = role; self.text = text; self.timestamp = timestamp; self.toolName = toolName
    }
}
public struct SessionHistorySession: Identifiable, Codable, Sendable, Equatable {
    public var id: String
    public var nativeSessionID: String
    public var agent: SessionHistoryAgent
    public var projectPath: String
    public var title: String
    public var sourcePath: String
    public var updatedAt: Date
    /// Empty in repository snapshots; use repository.session(id:) for the selected transcript.
    public var messages: [SessionHistoryMessage]
    /// Indexed readable message count, independent of whether content is loaded.
    public var messageCount: Int
    public var warnings: [String]
    public var isFavorite: Bool
    public var isAvailable: Bool
    public init(id: String, nativeSessionID: String, agent: SessionHistoryAgent, projectPath: String, title: String, sourcePath: String, updatedAt: Date, messages: [SessionHistoryMessage], warnings: [String] = [], isFavorite: Bool = false, isAvailable: Bool = true) {
        self.id = id; self.nativeSessionID = nativeSessionID; self.agent = agent; self.projectPath = projectPath
        self.title = title; self.sourcePath = sourcePath; self.updatedAt = updatedAt; self.messages = messages; self.messageCount = messages.count
        self.warnings = warnings; self.isFavorite = isFavorite; self.isAvailable = isAvailable
    }
}
public struct SessionHistorySnapshot: Sendable {
    public var sessions: [SessionHistorySession]
    public var issues: [String]
    public var refreshedAt: Date?
    public init(sessions: [SessionHistorySession] = [], issues: [String] = [], refreshedAt: Date? = nil) {
        self.sessions = sessions; self.issues = issues; self.refreshedAt = refreshedAt
    }
}
public struct SessionHistorySearchResult: Identifiable, Sendable {
    public var sessionID: String
    public var messageID: String
    public var excerpt: String
    public var id: String { sessionID + "|" + messageID }
}
public enum SessionHistoryExport {
    public static func markdown(session: SessionHistorySession) -> String {
        var output = "# \(session.title)\n\nAgent: \(session.agent.displayName)\n\nSession: \(session.nativeSessionID)\n\nProject: \(session.projectPath)\n\nSource: \(session.sourcePath)\n\n"
        if !session.isAvailable { output += "> Source unavailable; cached history.\n\n" }
        for warning in session.warnings { output += "> \(warning)\n\n" }
        for message in session.messages {
            output += "## \(message.role.rawValue.capitalized)\(message.toolName.map { " — " + $0 } ?? "")\n\n"
            if message.role == .tool {
                let fence = String(repeating: "`", count: max(3, message.text.split(whereSeparator: { $0 != "`" }).map(\.count).max().map { $0 + 1 } ?? 3))
                output += fence + "text\n" + message.text + "\n" + fence + "\n\n"
            } else { output += message.text + "\n\n" }
        }
        return output
    }
}
