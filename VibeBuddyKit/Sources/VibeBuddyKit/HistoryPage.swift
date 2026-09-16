import Foundation

/// Native transcript identity shared by Mac selection and the phone. No title/path lookup.
public enum HistoryIdentity {
    public static func transcriptKey(for session: AgentSession) -> String? {
        let agent: String
        switch session.agent {
        case .claudeCode: agent = "claude-code"
        case .codex: agent = "codex"
        case .cursor: agent = "cursor"
        default: return nil
        }
        guard !session.id.isEmpty, session.id.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || "-_".unicodeScalars.contains($0) }) else { return nil }
        return agent + ":" + session.id
    }
}

/// raw-visible-v1 preserves parser message IDs and Foundation Codable dates.
/// Offsets are not Mac/MCP grouped sequence references.
public struct HistoryMessage: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var role: String
    public var text: String
    public var timestamp: Date?
    public var toolName: String?
    public var kind: String?
    public var groupID: String?
    public var toolCallID: String?
    public var isToolOutput: Bool?
    public var isError: Bool?
}

public struct HistoryPage: Codable, Sendable, Equatable {
    public var sourceID: String
    public var key: String
    public var projection: String
    public var revision: String
    public var messages: [HistoryMessage]
    public var start: Int
    public var end: Int
    public var totalMessages: Int
    public var nextCursor: String?
    public var coverage: String
    public var sourceLimitReached: Bool
    public var sourceAvailable: Bool
    public var provenance: String
    public var warnings: [String]

    public init(sourceID: String, key: String, revision: String, messages: [HistoryMessage], start: Int,
                end: Int, totalMessages: Int, nextCursor: String?, coverage: String,
                sourceLimitReached: Bool, warnings: [String]) {
        self.sourceID = sourceID; self.key = key; projection = "raw-visible-v1"; self.revision = revision
        self.messages = messages; self.start = start; self.end = end; self.totalMessages = totalMessages
        self.nextCursor = nextCursor; self.coverage = coverage; self.sourceLimitReached = sourceLimitReached
        sourceAvailable = true; provenance = "source"; self.warnings = warnings
    }
}

public struct HistoryFailure: Error, Codable, Sendable, Equatable {
    public var reason: String
    public init(_ reason: String) { self.reason = reason }
    public var invalidatesPages: Bool { ["revision_changed", "cursor_expired", "source_changed"].contains(reason) }
}
