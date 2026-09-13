import Foundation

/// Stable identities for the evidence that supports a session state. These raw
/// values are part of the Mac-to-phone wire contract.
public enum ObservationSource: String, Codable, Sendable, CaseIterable, Comparable {
    /// The Codex app-server daemon's own JSON-RPC notifications, read over its
    /// local control socket. Authoritative for Codex when fresh; rollout and
    /// hook evidence for the same thread then only corroborates.
    case appserver
    /// Cursor's Cloud Agents API. A cloud agent runs on Cursor's machines, so no
    /// hook fires and no transcript is written for it; this is the only live
    /// source there is for one, and it speaks for `bc-`-prefixed conversations
    /// alone. Local Cursor conversations are unaffected by it.
    case cloud
    case gateway
    case hook
    /// Claude Code's status line JSON, forwarded by vibebuddy's wrapper script
    /// on every event: context, cost, session name, effort, PR, worktree and
    /// rate limits. Only ever fills fields on a known session.
    case statusline
    case rollout
    case transcript
    case recovery
    /// A `cursor-agent acp` process vibebuddy itself hosts: its `session/update`
    /// notifications are the live source for that conversation, and the same
    /// pipe carries the answers.
    case acp

    public static func < (lhs: Self, rhs: Self) -> Bool {
        guard let left = allCases.firstIndex(of: lhs),
              let right = allCases.firstIndex(of: rhs) else { return false }
        return left < right
    }

    public var displayName: String {
        switch self {
        case .appserver: String(localized: "App server", bundle: .module)
        case .cloud: String(localized: "Cursor cloud", bundle: .module)
        case .gateway: String(localized: "Grok Bot gateway", bundle: .module)
        case .hook: String(localized: "Hook", bundle: .module)
        case .statusline: String(localized: "Status line", bundle: .module)
        case .rollout: String(localized: "Rollout", bundle: .module)
        case .transcript: String(localized: "Transcript", bundle: .module)
        case .recovery: String(localized: "Recovery", bundle: .module)
        case .acp: String(localized: "Cursor CLI (ACP)", bundle: .module)
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
        case .healthy: String(localized: "Healthy", bundle: .module)
        case .temporarilySilent: String(localized: "Temporarily silent", bundle: .module)
        case .eventsMissing: String(localized: "Events missing", bundle: .module)
        case .asyncIncompatible: String(localized: "Async incompatible", bundle: .module)
        case .sourceUnreadable: String(localized: "Unreadable", bundle: .module)
        case .notInstalled: String(localized: "Not installed", bundle: .module)
        case .unknownVersion: String(localized: "Unknown version", bundle: .module)
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
            return "The approval hook is installed as asynchronous, so the agent never waits for the answer. Repair the installation."
        case .sourceUnreadable:
            switch source {
            case .gateway: return "The Grok Bot gateway cannot be reached. Open Grok Bot and check its connection."
            case .appserver: return "The Codex app-server control socket cannot be reached."
            case .cloud: return "Cursor's Cloud Agents API cannot be reached. Check the API key in Settings."
            case .statusline: return "The status line forwarder is not installed in Claude's settings."
            case .rollout: return "The rollout stream cannot be read."
            case .transcript: return "The transcript cannot be read."
            case .hook: return "The hook configuration cannot be read."
            case .recovery: return "The recovery source cannot be read."
            case .acp: return "The Cursor CLI process vibebuddy started is not answering. Check that cursor-agent is installed and signed in."
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
    /// Extensible diagnostic metadata; existing health raw values stay on the wire.
    public var reasonCode: String?
    public var sourceVersion: String?
    public var configuredCoverage: [ObservationEventCoverage]
    public var observedCoverage: [ObservationEventCoverage]

    public init(
        source: ObservationSource,
        health: ObservationHealth,
        lastObservedAt: Date? = nil,
        configuredCoverage: [ObservationEventCoverage] = [],
        observedCoverage: [ObservationEventCoverage] = [],
        reasonCode: String? = nil,
        sourceVersion: String? = nil
    ) {
        self.source = source
        self.health = health
        self.lastObservedAt = lastObservedAt
        self.reasonCode = reasonCode
        self.sourceVersion = sourceVersion
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
        if historyOnly == true { return String(localized: "Stored conversation · live status unavailable", bundle: .module) }
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
