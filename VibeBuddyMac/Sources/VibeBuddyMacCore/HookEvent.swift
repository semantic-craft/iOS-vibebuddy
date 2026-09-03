import Foundation
import VibeBuddyKit

/// A normalized lifecycle event from a coding agent's hook, after the raw hook
/// JSON has been parsed. The reducer consumes these. Parsing the raw payload
/// (Claude Code vs Codex shapes) is a separate, additive concern.
public struct HookEvent: Sendable, Equatable {
    public enum Kind: String, Sendable {
        case sessionStart
        case userPromptSubmit
        case preToolUse
        case postToolUse
        case notification
        case stop
        case sessionEnd
        /// Session metadata changed without implying any progress transition.
        /// Claude emits this for model and working-directory changes.
        case sessionMetadataChanged
        /// Teammate / subagent / task start, stop, or idle. Must not move the
        /// parent session's three-state progress.
        case childLifecycle
    }

    public enum ChildLifecycleAction: String, Sendable, Equatable {
        case started
        case stopped
        case idled
        /// Identity exists but running/done cannot be claimed, or an
        /// unattributed wait/end arrived. Must not be inferred from time.
        case unknown
    }

    public let kind: Kind
    public let sessionID: String
    public let agent: AgentKind
    public let cwd: String?
    public let toolName: String?
    public let message: String?
    public let transcriptPath: String?
    public let model: String?
    /// Nil means the caller has not classified transport yet. Raw hook intake
    /// supplies `.hook`; the normalized Codex monitor path supplies `.rollout`.
    public let observationSource: ObservationSource?
    /// A `PostToolUse` whose tool reported an error (non-zero exit, `is_error`,
    /// or interruption). Drives the session's `failed`/stuck signal.
    public let toolError: Bool
    public let timestamp: Date
    /// Stable child identity (`subagent:<agent_id>`, `task:<task_id>`,
    /// `teammate:<team>/<name>`). Nil when the payload lacked an identity.
    public let childID: String?
    public let childKind: ChildAgentKind?
    public let childName: String?
    public let childType: String?
    public let childAction: ChildLifecycleAction?
    /// Per-turn identity when the CLI supplies one (Grok's `promptId`). Lets the
    /// reducer drop a settle report that belongs to an already-superseded turn.
    /// Nil for CLIs that do not label turns — those settle unconditionally.
    public let turnID: String?
    /// Model, token, and context facts a local source read alongside the event
    /// (the Codex rollout's `token_count`). Applied through the reducer's
    /// enrichment path, never as a progress transition.
    public let enrichment: TranscriptInfo?
    /// The Codex Desktop thread this event belongs to. Only the rollout tailer
    /// sets it, and only for sessions the rollout itself declares as Desktop —
    /// which is the sole place that fact is known. Nil everywhere else, and the
    /// reducer reads it as "this session is a Desktop thread, jumpable through
    /// ChatGPT.app rather than through a terminal".
    public let desktopThreadID: String?

    public init(
        kind: Kind,
        sessionID: String,
        agent: AgentKind = .claudeCode,
        cwd: String? = nil,
        toolName: String? = nil,
        message: String? = nil,
        transcriptPath: String? = nil,
        model: String? = nil,
        observationSource: ObservationSource? = nil,
        toolError: Bool = false,
        timestamp: Date,
        childID: String? = nil,
        childKind: ChildAgentKind? = nil,
        childName: String? = nil,
        childType: String? = nil,
        childAction: ChildLifecycleAction? = nil,
        turnID: String? = nil,
        enrichment: TranscriptInfo? = nil,
        desktopThreadID: String? = nil
    ) {
        self.kind = kind
        self.sessionID = sessionID
        self.agent = agent
        self.cwd = cwd
        self.toolName = toolName
        self.message = message
        self.transcriptPath = transcriptPath
        self.model = model
        self.observationSource = observationSource
        self.toolError = toolError
        self.timestamp = timestamp
        self.childID = childID
        self.childKind = childKind
        self.childName = childName
        self.childType = childType
        self.childAction = childAction
        self.turnID = turnID
        self.enrichment = enrichment
        self.desktopThreadID = desktopThreadID
    }
}
