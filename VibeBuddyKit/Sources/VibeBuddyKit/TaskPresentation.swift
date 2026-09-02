import Foundation

/// Platform-neutral task state used by every status surface.
///
/// This is deliberately separate from `SessionStatus`: the latter describes the
/// agent lifecycle, while this type describes what a person should see now.
public enum TaskPresentationState: String, Codable, Sendable, CaseIterable, Hashable {
    case idle
    case thinking
    case completeUnread
    case requiresInput
    case error
    case unassigned

    /// Most urgent state sorts first. `unassigned` is a slot/placeholder state,
    /// never a real session state.
    public var attentionRank: Int {
        switch self {
        case .error: return 0
        case .requiresInput: return 1
        case .thinking: return 2
        case .completeUnread: return 3
        case .idle: return 4
        case .unassigned: return 5
        }
    }

    public var label: String {
        switch self {
        case .idle: return "Idle"
        case .thinking: return "Thinking"
        case .completeUnread: return "Complete, unread update"
        case .requiresInput: return "Requires input"
        case .error: return "Error"
        case .unassigned: return "No assigned task"
        }
    }

    public var symbolName: String {
        switch self {
        case .idle: return "circle"
        case .thinking: return "ellipsis"
        case .completeUnread: return "checkmark"
        case .requiresInput: return "exclamationmark"
        case .error: return "xmark"
        case .unassigned: return "minus"
        }
    }

    public var colorToken: TaskStatusColorToken {
        switch self {
        case .idle: return .idle
        case .thinking: return .thinking
        case .completeUnread: return .completeUnread
        case .requiresInput: return .requiresInput
        case .error: return .error
        case .unassigned: return .off
        }
    }

    /// The single pure domain-to-presentation projection.
    public static func project(
        status: SessionStatus,
        waitKind: WaitKind?,
        failed: Bool,
        hasUnreadCompletion: Bool
    ) -> TaskPresentationState {
        if failed { return .error }
        if status == .needsResponse { return .requiresInput }
        if status == .working { return .thinking }
        if status == .done, hasUnreadCompletion { return .completeUnread }
        return .idle
    }
}

/// Exact sRGB implementation tokens for task status colors.
///
/// OpenAI's Codex Micro documentation defines the semantic color names but not
/// RGB/Hex values. These values are the observed ChatGPT Desktop 26.825.51511
/// Codex Micro implementation snapshot, checked 2026-09-02. If a public token
/// specification changes, this is the one source to update.
public struct TaskStatusColorToken: Codable, Sendable, Hashable {
    public let red: UInt8
    public let green: UInt8
    public let blue: UInt8

    public init(red: UInt8, green: UInt8, blue: UInt8) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    public var hex: String {
        String(format: "#%02X%02X%02X", red, green, blue)
    }

    public static let idle = TaskStatusColorToken(red: 0xFF, green: 0xFF, blue: 0xFF)
    public static let thinking = TaskStatusColorToken(red: 0x30, green: 0x4F, blue: 0xFE)
    public static let completeUnread = TaskStatusColorToken(red: 0x00, green: 0xFF, blue: 0x4C)
    public static let requiresInput = TaskStatusColorToken(red: 0xFF, green: 0x6D, blue: 0x00)
    public static let error = TaskStatusColorToken(red: 0xFF, green: 0x00, blue: 0x33)
    public static let off = TaskStatusColorToken(red: 0x00, green: 0x00, blue: 0x00)
}

public extension AgentSession {
    var presentationState: TaskPresentationState {
        TaskPresentationState.project(
            status: status,
            waitKind: waitKind,
            failed: isStuck,
            hasUnreadCompletion: hasUnreadCompletion
        )
    }
}

/// Aggregate counts used by Mac, iPhone, Live Activity, Dynamic Island, and the
/// widget extension. It is derived exclusively from the shared projection.
public struct TaskPresentationSummary: Codable, Sendable, Hashable {
    public var idle: Int
    public var thinking: Int
    public var completeUnread: Int
    public var requiresInput: Int
    public var error: Int

    public init(idle: Int = 0, thinking: Int = 0, completeUnread: Int = 0,
                requiresInput: Int = 0, error: Int = 0) {
        self.idle = idle
        self.thinking = thinking
        self.completeUnread = completeUnread
        self.requiresInput = requiresInput
        self.error = error
    }

    public init(sessions: [AgentSession]) {
        var result = TaskPresentationSummary()
        for session in sessions {
            switch session.presentationState {
            case .idle: result.idle += 1
            case .thinking: result.thinking += 1
            case .completeUnread: result.completeUnread += 1
            case .requiresInput: result.requiresInput += 1
            case .error: result.error += 1
            case .unassigned: break
            }
        }
        self = result
    }

    public var total: Int { idle + thinking + completeUnread + requiresInput + error }
    public var isEmpty: Bool { total == 0 }

    public var primaryState: TaskPresentationState {
        if error > 0 { return .error }
        if requiresInput > 0 { return .requiresInput }
        if thinking > 0 { return .thinking }
        if completeUnread > 0 { return .completeUnread }
        if idle > 0 { return .idle }
        return .unassigned
    }

    public func count(for state: TaskPresentationState) -> Int {
        switch state {
        case .idle: return idle
        case .thinking: return thinking
        case .completeUnread: return completeUnread
        case .requiresInput: return requiresInput
        case .error: return error
        case .unassigned: return 0
        }
    }
}

/// Small cross-process snapshot for the static Widget. It contains presentation
/// data only, so the Widget cannot invent its own lifecycle or unread truth.
public struct TaskPresentationSnapshot: Codable, Sendable, Hashable {
    public var summary: TaskPresentationSummary
    public var topProject: String?
    public var topSessionId: String?
    public var updatedAt: Date

    public init(summary: TaskPresentationSummary = TaskPresentationSummary(),
                topProject: String? = nil, topSessionId: String? = nil,
                updatedAt: Date = Date()) {
        self.summary = summary
        self.topProject = topProject
        self.topSessionId = topSessionId
        self.updatedAt = updatedAt
    }

    public init(sessions: [AgentSession], updatedAt: Date = Date()) {
        let leading = sessions.leadingPresentationSession
        self.init(summary: TaskPresentationSummary(sessions: sessions),
                  topProject: leading?.project, topSessionId: leading?.id,
                  updatedAt: updatedAt)
    }
}

public extension Array where Element == AgentSession {
    /// The task an aggregate surface should focus, using presentation priority
    /// and then recency. Empty arrays have no assigned task.
    var leadingPresentationSession: AgentSession? {
        self.min {
            if $0.presentationState.attentionRank != $1.presentationState.attentionRank {
                return $0.presentationState.attentionRank < $1.presentationState.attentionRank
            }
            return $0.updatedAt > $1.updatedAt
        }
    }
}
