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

/// What the client may honestly say after a send. Accepted means the daemon
/// took the request — not that the session is working or finished.
public enum SessionActionOutcome: Equatable, Sendable {
    case notSent(String)
    case accepted
    case failed(String)
    case unknown
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
        if let question = session.pendingQuestion {
            let reason = question.isAnswerable
                ? nil
                : String(localized: "You're at the Mac — answer this in the agent's own prompt.")
            return SessionActionSupport(intent: .answer, unsupportedReason: reason)
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
    public var text: String?
    public var answers: QuestionAnswers?

    public init(sessionID: String,
                intent: SessionActionIntent? = nil,
                requestID: String = UUID().uuidString,
                questionID: String? = nil,
                text: String? = nil,
                answers: QuestionAnswers? = nil) {
        self.sessionID = sessionID
        self.intent = intent
        self.requestID = requestID
        self.questionID = questionID
        self.text = text
        self.answers = answers
    }
}

public extension SessionActionOutcome {
    /// Map a daemon `/answer` HTTP result. No response at all is the caller's
    /// job (`notSent` before the request, `unknown` after a transport error).
    static func fromHTTP(statusCode: Int, body: [String: String]) -> SessionActionOutcome {
        switch body["status"] {
        case "accepted": return .accepted
        case "failed": return .failed(body["error"] ?? String(localized: "The Mac refused"))
        case "unknown": return .unknown
        default:
            if statusCode == 202 {
                return .failed(body["error"] ?? String(localized: "Not delivered"))
            }
            if (200..<300).contains(statusCode) { return .accepted }
            return .failed(body["error"] ?? String(localized: "The Mac refused"))
        }
    }
}
