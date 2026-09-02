import Foundation

/// Which coding agent a session belongs to. Source-agnostic by design — new
/// agents are added here without changing the rest of the wire model. Raw values
/// are stable wire strings; `claudeCode`/`codex` are kept for back-compat.
public enum AgentKind: String, Codable, Sendable, CaseIterable {
    case claudeCode
    case codex
    case qwen
    case kimi
    case antigravity
    case grok
    case opencode
    case copilot
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
    /// Rich detail for the phone's approval card. All optional and defaulted so
    /// older payloads decode and existing callers compile unchanged.
    public let command: String?      // full Bash command
    public let filePath: String?     // Edit/Write/Read target
    public let oldText: String?      // Edit: pre-image (for a diff)
    public let newText: String?      // Edit/Write: post-image / new content

    public init(id: String, tool: String, commandPreview: String,
                command: String? = nil, filePath: String? = nil,
                oldText: String? = nil, newText: String? = nil) {
        self.id = id
        self.tool = tool
        self.commandPreview = commandPreview
        self.command = command
        self.filePath = filePath
        self.oldText = oldText
        self.newText = newText
    }
}

/// A question the agent asked in the terminal, with optional pre-defined answers
/// that can be sent back by typing into the captured pane.
public struct QuestionOption: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let label: String
    public let value: String
    public let description: String?

    public init(id: String, label: String, value: String? = nil, description: String? = nil) {
        self.id = id
        self.label = label
        self.value = value ?? label
        self.description = description
    }
}

public struct PendingQuestion: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let prompt: String
    public let options: [QuestionOption]

    public init(id: String, prompt: String, options: [QuestionOption] = []) {
        self.id = id
        self.prompt = prompt
        self.options = options
    }
}

/// Identifies the terminal a session runs in, so the Mac can jump to it.
public struct TerminalRef: Codable, Sendable, Equatable {
    public let termProgram: String
    public let tty: String?
    public let tmux: String?
    public let tmuxPane: String?
    public init(termProgram: String, tty: String? = nil, tmux: String? = nil, tmuxPane: String? = nil) {
        self.termProgram = termProgram; self.tty = tty; self.tmux = tmux; self.tmuxPane = tmuxPane
    }
}

/// How a child of a parent session was observed. Raw values are stable wire strings.
public enum ChildAgentKind: String, Codable, Sendable {
    case subagent
    case task
    case teammate
}

/// Live child progress. `unknown` means identity or an end signal was insufficient.
public enum ChildAgentStatus: String, Codable, Sendable {
    case running
    case idle
    case completed
    case unknown
}

/// One teammate, subagent, or task attached to a parent session by a stable id.
public struct ChildAgent: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public var kind: ChildAgentKind
    public var name: String?
    public var type: String?
    public var status: ChildAgentStatus
    public var lastActivity: String?
    public var updatedAt: Date

    public init(
        id: String,
        kind: ChildAgentKind,
        name: String? = nil,
        type: String? = nil,
        status: ChildAgentStatus,
        lastActivity: String? = nil,
        updatedAt: Date
    ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.type = type
        self.status = status
        self.lastActivity = lastActivity
        self.updatedAt = updatedAt
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
    public var pendingQuestion: PendingQuestion?
    public var terminalRef: TerminalRef?
    public var summary: String?
    public var tokens: Int?
    /// Context consumed on the last turn (input + cache_read + cache_creation)
    /// and the model's context window, for the phone's usage bar. Both optional.
    public var contextTokens: Int?
    public var contextWindow: Int?
    /// The last turn / tool ended in an error (Bash non-zero exit, tool error,
    /// or a failure-looking Stop message). Optional so older payloads decode as
    /// "unknown"; drives the `agentStuck` cue and the buddy's worried face.
    public var failed: Bool?
    /// A clean completion result that has not yet been explicitly opened,
    /// selected, or jumped to. The Mac reducer is authoritative for this value.
    public var hasUnreadCompletion: Bool
    /// Cumulative tokens spent across this session's turns (input+output),
    /// accumulated by the reducer. Drives the estimated cost + budget alert.
    public var spentTokens: Int?
    /// The tool the agent is currently running (set on PreToolUse, cleared on
    /// PostToolUse / a new turn). Drives the Mac row's "Editing…/Searching…"
    /// activity line. Optional so older payloads decode as "unknown".
    public var activeTool: String?
    /// Stable evidence describing how this session was observed. Optional keeps
    /// snapshots from older Mac builds decodable by newer clients.
    public var observations: [ObservationEvidence]?
    /// Live teammate/subagent/task rows for this parent. Optional so older
    /// snapshots decode as "no topology yet"; recovery leaves this empty.
    public var childAgents: [ChildAgent]?
    /// True when a child event arrived without a stable identity. Optional so
    /// older payloads stay decodable and default to "not degraded".
    public var childTopologyDegraded: Bool?
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
        pendingQuestion: PendingQuestion? = nil,
        terminalRef: TerminalRef? = nil,
        summary: String? = nil,
        tokens: Int? = nil,
        contextTokens: Int? = nil,
        contextWindow: Int? = nil,
        failed: Bool? = nil,
        hasUnreadCompletion: Bool = false,
        spentTokens: Int? = nil,
        activeTool: String? = nil,
        observations: [ObservationEvidence]? = nil,
        childAgents: [ChildAgent]? = nil,
        childTopologyDegraded: Bool? = nil,
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
        self.pendingQuestion = pendingQuestion
        self.terminalRef = terminalRef
        self.summary = summary
        self.tokens = tokens
        self.contextTokens = contextTokens
        self.contextWindow = contextWindow
        self.failed = failed
        self.hasUnreadCompletion = hasUnreadCompletion
        self.spentTokens = spentTokens
        self.activeTool = activeTool
        self.observations = observations
        self.childAgents = childAgents
        self.childTopologyDegraded = childTopologyDegraded
        self.statusSince = statusSince
        self.updatedAt = updatedAt
    }

    /// Whether to treat this session as failed/stuck (Optional `failed` is "no").
    public var isStuck: Bool { failed == true }

    public var runningChildAgents: [ChildAgent] {
        (childAgents ?? []).filter { $0.status == .running }
    }

    public var runningChildAgentCount: Int { runningChildAgents.count }
}

/// Full state of every known session — sent on initial load and on reconnect.
public struct Snapshot: Codable, Sendable, Equatable {
    public var sessions: [AgentSession]
    public var serverTime: Date
    /// Mac-side source diagnostics, mirrored to iOS. Optional preserves wire
    /// compatibility with snapshots emitted before observability v2.
    public var observationDiagnostics: [AgentObservationDiagnostic]?

    public init(
        sessions: [AgentSession],
        serverTime: Date,
        observationDiagnostics: [AgentObservationDiagnostic]? = nil
    ) {
        self.sessions = sessions
        self.serverTime = serverTime
        self.observationDiagnostics = observationDiagnostics
    }
}

/// What the Mac encodes into the pairing QR; the phone scans and stores it.
/// `host` is a LAN IP today and a Tailscale 100.x IP later — same shape.
public struct PairingPayload: Codable, Sendable, Equatable {
    public var host: String
    public var port: Int
    public var token: String
    public var macName: String?

    public init(host: String, port: Int, token: String, macName: String? = nil) {
        self.host = host
        self.port = port
        self.token = token
        self.macName = macName
    }
}

/// What the paired iPhone reports back to the Mac after scanning the QR. The
/// APNs token is optional because the dashboard connection and push registration
/// can arrive in either order.
public struct DeviceRegistrationPayload: Codable, Sendable, Equatable {
    public var token: String?
    public var name: String?
    public var model: String?
    public var systemVersion: String?
    /// The phone's sound preferences, so the Mac's background push respects them.
    /// Optional so older payloads decode unchanged.
    public var playSound: Bool?
    public var quietMode: Bool?

    public init(token: String? = nil, name: String? = nil,
                model: String? = nil, systemVersion: String? = nil,
                playSound: Bool? = nil, quietMode: Bool? = nil) {
        self.token = token
        self.name = name
        self.model = model
        self.systemVersion = systemVersion
        self.playSound = playSound
        self.quietMode = quietMode
    }

    public var hasPushToken: Bool { token?.isEmpty == false }

    public var hasVisibleDeviceInfo: Bool {
        hasPushToken || name?.isEmpty == false || model?.isEmpty == false || systemVersion?.isEmpty == false
    }
}
