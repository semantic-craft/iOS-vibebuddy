import Foundation

/// Which coding agent a session belongs to. Source-agnostic by design — new
/// agents are added here without changing the rest of the wire model.
public enum AgentKind: String, Codable, Sendable, CaseIterable {
    case claudeCode
    case codex
}

/// The three buckets the dashboard cares about.
public enum SessionStatus: String, Codable, Sendable, CaseIterable {
    case needsResponse   // ② your turn — permission / waiting for input
    case working         // ③ actively running
    case done            // ① turn ended, idle

    /// Display priority for the dashboard: lower sorts first (most urgent).
    public var attentionRank: Int {
        switch self {
        case .needsResponse: return 0
        case .working: return 1
        case .done: return 2
        }
    }
}

/// Why a session needs the user — only meaningful when `status == .needsResponse`.
public enum WaitKind: String, Codable, Sendable {
    case permission      // blocked on an approve/deny
    case question        // asked something / idle waiting for input
}

/// A tool use awaiting the user's approval from the phone. Present only while a
/// session is blocked on a remote approve/deny.
public struct PendingApproval: Codable, Sendable, Equatable {
    public let id: String
    public let tool: String
    public let commandPreview: String

    public init(id: String, tool: String, commandPreview: String) {
        self.id = id
        self.tool = tool
        self.commandPreview = commandPreview
    }
}

/// One coding-agent session, as broadcast to the phone.
public struct AgentSession: Codable, Identifiable, Sendable, Equatable {
    public let id: String
    public let agent: AgentKind
    public var project: String
    public var branch: String?
    public var model: String?
    public var status: SessionStatus
    public var waitKind: WaitKind?
    public var pendingApproval: PendingApproval?
    public var summary: String?
    public var tokens: Int?
    public var statusSince: Date
    public var updatedAt: Date

    public init(
        id: String,
        agent: AgentKind,
        project: String,
        branch: String? = nil,
        model: String? = nil,
        status: SessionStatus,
        waitKind: WaitKind? = nil,
        pendingApproval: PendingApproval? = nil,
        summary: String? = nil,
        tokens: Int? = nil,
        statusSince: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.agent = agent
        self.project = project
        self.branch = branch
        self.model = model
        self.status = status
        self.waitKind = waitKind
        self.pendingApproval = pendingApproval
        self.summary = summary
        self.tokens = tokens
        self.statusSince = statusSince
        self.updatedAt = updatedAt
    }
}

/// Full state of every known session — sent on initial load and on reconnect.
public struct Snapshot: Codable, Sendable, Equatable {
    public var sessions: [AgentSession]
    public var serverTime: Date

    public init(sessions: [AgentSession], serverTime: Date) {
        self.sessions = sessions
        self.serverTime = serverTime
    }
}

/// What the Mac encodes into the pairing QR; the phone scans and stores it.
/// `host` is a LAN IP today and a Tailscale 100.x IP later — same shape.
public struct PairingPayload: Codable, Sendable, Equatable {
    public var host: String
    public var port: Int
    public var token: String

    public init(host: String, port: Int, token: String) {
        self.host = host
        self.port = port
        self.token = token
    }
}
