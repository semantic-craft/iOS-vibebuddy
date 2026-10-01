import Foundation

public enum TaskReadKind: String, Codable, Sendable, CaseIterable { case goal, history, terminals }
public struct TaskReadCapabilities: Codable, Sendable {
    public var sourceID: String
    public var supported: [TaskReadKind]
    public init(sourceID: String, supported: [TaskReadKind]) { self.sourceID = sourceID; self.supported = supported }
}
/// Independent from live state and completion receipts. Cursors are opaque and source-scoped.
public struct TaskReadResponse: Codable, Sendable {
    public var sourceID: String
    public var sessionID: String
    public var kind: TaskReadKind
    public var observedAt: Date
    public var provenance = "codex-app-server"
    public var failure: String?
    public var goal: CodexTaskGoal?
    public var messages: [HistoryMessage]?
    public var terminals: [CodexBackgroundTerminal]?
    public var nextCursor: String?
    public init(sourceID: String, sessionID: String, kind: TaskReadKind, observedAt: Date = Date()) {
        self.sourceID = sourceID; self.sessionID = sessionID; self.kind = kind; self.observedAt = observedAt
    }
}

public struct CodexTaskGoal: Codable, Equatable, Sendable {
    public let threadId: String
    public let objective: String
    public let status: String
    public let tokensUsed: Int64
    public let tokenBudget: Int64?
    public let timeUsedSeconds: Int64
    public let updatedAt: Int64
}

public struct CodexBackgroundTerminal: Codable, Equatable, Identifiable, Sendable {
    public let processId: String
    public let command: String
    public let cwd: String
    public let osPid: UInt32?
    public let cpuPercent: Double?
    public let rssKb: UInt64?
    public var id: String { processId }
}

public struct CodexTerminalPage: Codable, Equatable, Sendable {
    public let data: [CodexBackgroundTerminal]
    public let nextCursor: String?
}
