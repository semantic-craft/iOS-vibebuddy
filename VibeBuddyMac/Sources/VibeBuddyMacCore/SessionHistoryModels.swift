import Foundation

public enum SessionHistoryAgent: String, Codable, Sendable, CaseIterable {
    case claude, codex, grokBuild
    public var displayName: String {
        switch self { case .claude: "Claude Code"; case .codex: "Codex"; case .grokBuild: "Grok Build" }
    }
    public var keyName: String {
        switch self { case .claude: "claude-code"; case .codex: "codex"; case .grokBuild: "grok-build" }
    }
    public var supportsTranscript: Bool { self != .grokBuild }
}
public enum SessionHistoryRole: String, Codable, Sendable { case user, assistant, tool, system }
public enum SessionHistoryMessageKind: String, Codable, Sendable { case text, meta, thinking, compactSummary }
public struct SessionHistoryMessage: Identifiable, Codable, Sendable, Equatable {
    public var id: String
    public var role: SessionHistoryRole
    public var text: String
    public var timestamp: Date?
    public var toolName: String?
    public var kind: SessionHistoryMessageKind?
    public var groupID: String?
    public var toolCallID: String?
    public var isToolOutput: Bool?
    public var isError: Bool?
    public init(id: String, role: SessionHistoryRole, text: String, timestamp: Date? = nil, toolName: String? = nil, kind: SessionHistoryMessageKind? = nil, groupID: String? = nil, toolCallID: String? = nil, isToolOutput: Bool = false, isError: Bool = false) {
        self.id = id; self.role = role; self.text = text; self.timestamp = timestamp; self.toolName = toolName
        self.kind = kind; self.groupID = groupID; self.toolCallID = toolCallID; self.isToolOutput = isToolOutput; self.isError = isError
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
    public var sourceArchived: Bool?
    public var source: String?
    public var sourceRevision: String?
    public var isPinned: Bool?
    public var archivedLocally: Bool?
    public var isArchived: Bool { sourceArchived == true || archivedLocally == true }
    public init(id: String, nativeSessionID: String, agent: SessionHistoryAgent, projectPath: String, title: String, sourcePath: String, updatedAt: Date, messages: [SessionHistoryMessage], warnings: [String] = [], isFavorite: Bool = false, isAvailable: Bool = true, sourceArchived: Bool = false, source: String? = nil) {
        self.id = id; self.nativeSessionID = nativeSessionID; self.agent = agent; self.projectPath = projectPath
        self.title = title; self.sourcePath = sourcePath; self.updatedAt = updatedAt; self.messages = messages; self.messageCount = messages.count
        self.sourceArchived = sourceArchived; self.source = source
        self.warnings = warnings; self.isFavorite = isFavorite; self.isAvailable = isAvailable
    }
}
public struct SessionHistorySnapshot: Sendable {
    public var sessions: [SessionHistorySession]
    public var issues: [String]
    public var refreshedAt: Date?
    public var pendingSourceCount: Int
    public init(sessions: [SessionHistorySession] = [], issues: [String] = [], refreshedAt: Date? = nil, pendingSourceCount: Int = 0) {
        self.sessions = sessions; self.issues = issues; self.refreshedAt = refreshedAt; self.pendingSourceCount = pendingSourceCount
    }
}
public struct SessionHistorySearchResult: Identifiable, Sendable {
    public var sessionID: String
    public var messageID: String
    public var excerpt: String
    public var id: String { sessionID + "|" + messageID }
    public init(sessionID: String, messageID: String, excerpt: String) {
        self.sessionID = sessionID; self.messageID = messageID; self.excerpt = excerpt
    }
}
public enum SessionHistoryExport {
    public static func markdown(session: SessionHistorySession) -> String {
        var output = "# \(session.title)\n\nAgent: \(session.agent.displayName)\n\nSession: \(session.nativeSessionID)\n\nProject: \(session.projectPath)\n\nSource: \(session.sourcePath)\n\n"
        if session.sourceArchived == true { output += "> Archived in the source agent.\n\n" }
        if !session.isAvailable { output += "> Source unavailable; cached history.\n\n" }
        for warning in session.warnings { output += "> \(warning)\n\n" }
        for message in session.messages where message.kind != .meta && message.kind != .thinking {
            if message.kind == .compactSummary { output += "## Context compacted\n\n"; continue }
            output += "## \(message.role.rawValue.capitalized)\(message.toolName.map { " — " + $0 } ?? "")\n\n"
            if message.role == .tool {
                let fence = String(repeating: "`", count: max(3, message.text.split(whereSeparator: { $0 != "`" }).map(\.count).max().map { $0 + 1 } ?? 3))
                output += fence + "text\n" + message.text + "\n" + fence + "\n\n"
            } else { output += message.text + "\n\n" }
        }
        return output
    }
}
