import Foundation

/// Stable identities for the evidence that supports a session state. These raw
/// values are part of the Mac-to-phone wire contract.
public enum ObservationSource: String, Codable, Sendable, CaseIterable, Comparable {
    /// The Codex app-server daemon's own JSON-RPC notifications, read over its
    /// local control socket. Authoritative for Codex when fresh; rollout and
    /// hook evidence for the same thread then only corroborates.
    case appserver
    case hook
    /// Claude Code's status line JSON, forwarded by vibebuddy's wrapper script
    /// on every event: context, cost, session name, effort, PR, worktree and
    /// rate limits. Only ever fills fields on a known session.
    case statusline
    case rollout
    case transcript
    case recovery

    public static func < (lhs: Self, rhs: Self) -> Bool {
        guard let left = allCases.firstIndex(of: lhs),
              let right = allCases.firstIndex(of: rhs) else { return false }
        return left < right
    }

    public var displayName: String {
        switch self {
        case .appserver: "App server"
        case .hook: "Hook"
        case .statusline: "Status line"
        case .rollout: "Rollout"
        case .transcript: "Transcript"
        case .recovery: "Recovery"
        }
    }
}

/// Observation health is deliberately separate from `SessionStatus`: a broken
/// diagnostic must never manufacture working, waiting, or done progress.
public enum ObservationHealth: String, Codable, Sendable, CaseIterable {
    case healthy
    case temporarilySilent
    case eventsMissing
    case asyncIncompatible
    case sourceUnreadable
    case notInstalled
    case unknownVersion

    public var displayName: String {
        switch self {
        case .healthy: "Healthy"
        case .temporarilySilent: "Temporarily silent"
        case .eventsMissing: "Events missing"
        case .asyncIncompatible: "Async incompatible"
        case .sourceUnreadable: "Unreadable"
        case .notInstalled: "Not installed"
        case .unknownVersion: "Unknown version"
        }
    }

    public var isHealthy: Bool { self == .healthy }

    public func explanation(for source: ObservationSource) -> String {
        switch self {
        case .healthy:
            return "Signals are arriving normally."
        case .temporarilySilent:
            return "This source reported before but has been quiet recently."
        case .eventsMissing:
            return "Required lifecycle events have not been observed."
        case .asyncIncompatible:
            return "Codex ignores asynchronous command hooks in this version."
        case .sourceUnreadable:
            switch source {
            case .appserver: return "The Codex app-server control socket cannot be reached."
            case .statusline: return "The status line forwarder is not installed in Claude's settings."
            case .rollout: return "The rollout stream cannot be read."
            case .transcript: return "The transcript cannot be read."
            case .hook: return "The hook configuration cannot be read."
            case .recovery: return "The recovery source cannot be read."
            }
        case .notInstalled:
            return "The agent is not installed or has no local configuration."
        case .unknownVersion:
            return "The source version or event shape is not recognized."
        }
    }
}

/// Coarse event families make coverage useful across Claude and Codex without
/// leaking either tool's raw event vocabulary into the shared UI.
public enum ObservationEventCoverage: String, Codable, Sendable, CaseIterable, Comparable {
    case lifecycle
    case turn
    case tool
    case attention

    public static func < (lhs: Self, rhs: Self) -> Bool {
        guard let left = allCases.firstIndex(of: lhs),
              let right = allCases.firstIndex(of: rhs) else { return false }
        return left < right
    }

    public var displayName: String {
        switch self {
        case .lifecycle: "Session"
        case .turn: "Turn"
        case .tool: "Tool"
        case .attention: "Attention"
        }
    }
}

/// Per-session evidence. One entry exists per stable source identity; repeated
/// signals update the entry instead of appending duplicates.
public struct ObservationEvidence: Codable, Sendable, Equatable {
    public let source: ObservationSource
    public var lastObservedAt: Date
    public var health: ObservationHealth

    public init(source: ObservationSource, lastObservedAt: Date, health: ObservationHealth) {
        self.source = source
        self.lastObservedAt = lastObservedAt
        self.health = health
    }
}

/// One source row in Settings diagnostics.
public struct ObservationSourceDiagnostic: Codable, Sendable, Equatable, Identifiable {
    public var id: ObservationSource { source }
    public let source: ObservationSource
    public var health: ObservationHealth
    public var lastObservedAt: Date?
    public var configuredCoverage: [ObservationEventCoverage]
    public var observedCoverage: [ObservationEventCoverage]

    public init(
        source: ObservationSource,
        health: ObservationHealth,
        lastObservedAt: Date? = nil,
        configuredCoverage: [ObservationEventCoverage] = [],
        observedCoverage: [ObservationEventCoverage] = []
    ) {
        self.source = source
        self.health = health
        self.lastObservedAt = lastObservedAt
        self.configuredCoverage = configuredCoverage.sorted()
        self.observedCoverage = observedCoverage.sorted()
    }
}

/// Diagnostics for one agent, carried in snapshots so Mac and iOS render the
/// same facts and copy.
public struct AgentObservationDiagnostic: Codable, Sendable, Equatable, Identifiable {
    public var id: AgentKind { agent }
    public let agent: AgentKind
    public var sources: [ObservationSourceDiagnostic]

    public init(agent: AgentKind, sources: [ObservationSourceDiagnostic]) {
        self.agent = agent
        self.sources = sources.sorted { $0.source < $1.source }
    }
}

public extension AgentSession {
    /// Compact copy shared by the Mac and iOS session rows.
    var observationDescription: String? {
        guard let observations, !observations.isEmpty else { return nil }
        let sorted = observations.sorted { $0.source < $1.source }
        let sources = sorted.map(\.source.displayName).joined(separator: " + ")
        let health = sorted.first(where: { !$0.health.isHealthy })?.health ?? .healthy
        return "\(sources) · \(health.displayName)"
    }

    var lastObservedAt: Date? {
        observations?.map(\.lastObservedAt).max()
    }
}

public extension ObservationSourceDiagnostic {
    var configuredCoverageDescription: String {
        coverageDescription(configuredCoverage)
    }

    var observedCoverageDescription: String {
        coverageDescription(observedCoverage)
    }

    private func coverageDescription(_ values: [ObservationEventCoverage]) -> String {
        values.sorted().map(\.displayName).joined(separator: ", ")
    }
}
