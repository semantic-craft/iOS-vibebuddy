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
        timestamp: Date
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
    }
}
