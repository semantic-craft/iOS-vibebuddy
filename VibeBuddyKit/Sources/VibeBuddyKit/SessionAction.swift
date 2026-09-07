import Foundation

/// What free text on an existing session means. Distinct from Approval
/// (native allow/deny) and from New task (a new session). Vision Q29.
public enum SessionActionIntent: String, Codable, Sendable {
    /// Bind to the current waiting question. An expired question must not
    /// become an instruction.
    case answer
    /// Join the running turn (`turn/steer`). Failure must not start a turn.
    case steer
    /// Open the next turn on a finished session (`turn/start`).
    case `continue`
}

/// Phone/Mac shared rule: which intent a session's composer should send,
/// and whether that agent can actually do it right now.
public struct SessionActionSupport: Equatable, Sendable {
    public var intent: SessionActionIntent
    public var unsupportedReason: String?

    public init(intent: SessionActionIntent, unsupportedReason: String? = nil) {
        self.intent = intent
        self.unsupportedReason = unsupportedReason
    }

    public var isAvailable: Bool { unsupportedReason == nil }

    public static func resolve(for session: AgentSession) -> SessionActionSupport {
        if session.agent == .grokBot {
            let intent: SessionActionIntent = session.status == .needsResponse ? .answer : session.status == .done ? .continue : .steer
            return SessionActionSupport(intent: intent, unsupportedReason: String(localized: "Respond in Grok Bot on your Mac. Remote instructions are unavailable."))
        }
        if session.status == .needsResponse {
            let handling = WaitHandling.resolve(for: session)
            let canAnswer = handling == .remoteAvailable && session.waitKind == .question
            return SessionActionSupport(intent: .answer, unsupportedReason: canAnswer ? nil :
                (handling == .remoteAvailable ? WaitHandling.macNativePrompt.message : handling.message))
        }
        let intent: SessionActionIntent = session.status == .done ? .continue : .steer
        guard session.agent == .codex else {
            return SessionActionSupport(
                intent: intent,
                unsupportedReason: String(localized: "\(session.agent.displayName) sessions can't take instructions from the phone yet — use the terminal."))
        }
        return SessionActionSupport(intent: intent)
    }

    /// Shown before send: which Mac, project and agent will receive this.
    public static func targetCaption(macName: String?, session: AgentSession) -> String {
        let trimmed = macName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let mac = trimmed.isEmpty ? String(localized: "Mac") : trimmed
        return "\(mac) · \(session.project) · \(session.agent.shortName)"
    }
}

/// Client → daemon payload for `/answer`. `intent` and `requestID` are how
/// the daemon refuses an expired answer and ignores a duplicate tap.
public struct SessionActionRequest: Equatable, Sendable {
    public var sessionID: String
    public var intent: SessionActionIntent?
    public var requestID: String
    public var questionID: String?
    public var expectedStatusSince: Double?
    public var text: String?
    public var answers: QuestionAnswers?

    public init(sessionID: String,
                intent: SessionActionIntent? = nil,
                requestID: String = UUID().uuidString,
                questionID: String? = nil,
                expectedStatusSince: Double? = nil,
                text: String? = nil,
                answers: QuestionAnswers? = nil) {
        self.sessionID = sessionID
        self.intent = intent
        self.requestID = requestID
        self.questionID = questionID
        self.expectedStatusSince = expectedStatusSince
        self.text = text
        self.answers = answers
    }
}

/// Snapshot capability only. Connection availability is evaluated by each device.
/// Bounded semantics travel in the existing Watch projection; no source text is needed.
public enum WaitHandling: String, Codable, Equatable, Sendable {
    case remoteAvailable
    case watchApproval
    case macNativePrompt
    case macGrokBot
    case unavailable

    public static func resolve(for session: AgentSession) -> WaitHandling {
        guard session.status == .needsResponse else { return .unavailable }
        if session.agent == .grokBot { return .macGrokBot }
        if session.waitKind == .permission {
            switch ApprovalEligibility.unavailableReason(for: session) {
            case nil: return .remoteAvailable
            case .readOnly, .unsupportedSource: return .macNativePrompt
            default: return .unavailable
            }
        }
        guard session.waitKind == .question,
              !session.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return .unavailable }
        guard let question = session.pendingQuestion else { return .macNativePrompt }
        guard !question.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .unavailable }
        return question.isAnswerable ? .remoteAvailable : .macNativePrompt
    }

    public var message: String {
        switch self {
        case .remoteAvailable: return String(localized: "Review and respond on your iPhone.")
        case .watchApproval: return String(localized: "Approve or deny on your Watch.")
        case .macNativePrompt: return String(localized: "Respond in the agent's own prompt on your Mac. Remote response is unavailable.")
        case .macGrokBot: return String(localized: "Respond in Grok Bot on your Mac. Remote response is unavailable.")
        case .unavailable: return String(localized: "This request can't be verified. Wait for an updated connection and request.")
        }
    }
}
