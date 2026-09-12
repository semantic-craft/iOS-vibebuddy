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
    /// Interrupt the running turn (`turn/interrupt`). Destructive and bound to
    /// the turn it was sent for: an expired stop must not end a later turn.
    case stop
}

/// Phone/Mac shared rule: which intent a session's composer should send,
/// and whether that agent can actually do it right now.
public struct SessionActionSupport: Equatable, Sendable {
    public var intent: SessionActionIntent
    public var unsupportedReason: String?
    /// Said when the action *is* available but does not land the way the intent
    /// reads. Cursor is the case it exists for: it has no way to interrupt a
    /// running turn, so a supplement is queued and Cursor's own `stop` hook
    /// submits it the moment the turn ends. The composer shows this so nobody
    /// taps Send expecting the agent to change course mid-tool-call.
    public var note: String?

    public init(intent: SessionActionIntent, unsupportedReason: String? = nil, note: String? = nil) {
        self.intent = intent
        self.unsupportedReason = unsupportedReason
        self.note = note
    }

    public var isAvailable: Bool { unsupportedReason == nil }

    public static func resolve(for session: AgentSession) -> SessionActionSupport {
        if session.agent == .grokBot {
            let intent: SessionActionIntent = session.status == .needsResponse ? .answer : session.status == .done ? .continue : .steer
            return SessionActionSupport(intent: intent, unsupportedReason: String(localized: "Respond in Grok Bot on your Mac. Remote instructions are unavailable.", bundle: .module))
        }
        if session.status == .needsResponse {
            let handling = WaitHandling.resolve(for: session)
            let canAnswer = handling == .remoteAvailable && session.waitKind == .question
            return SessionActionSupport(intent: .answer, unsupportedReason: canAnswer ? nil :
                (handling == .remoteAvailable ? WaitHandling.macNativePrompt.message : handling.message))
        }
        let intent: SessionActionIntent = session.status == .done ? .continue : .steer
        if session.agent == .cursor { return cursorSupport(intent: intent, session: session) }
        guard session.agent == .codex else {
            return SessionActionSupport(
                intent: intent,
                unsupportedReason: String(localized: "\(session.agent.displayName) sessions can't take instructions from the phone yet — use the terminal.", bundle: .module))
        }
        return SessionActionSupport(intent: intent)
    }

    /// Whether **stop** is available for this session right now, and why not.
    ///
    /// Separate from `resolve(for:)` because stop is not a composer intent: it
    /// carries no text and applies to a *running* turn, which is exactly when
    /// the composer would be steering. The first release interrupts Codex only
    /// (spec decision, 2026-09-08); every other agent is stopped where it runs.
    /// The daemon re-checks all of this against the live snapshot before it
    /// calls anything.
    public static func resolveStop(for session: AgentSession) -> SessionActionSupport {
        guard session.agent == .codex else {
            return SessionActionSupport(intent: .stop, unsupportedReason: stopUnsupportedReason(for: session.agent))
        }
        // A Codex session is visible through the rollout tailer and hooks too,
        // and those cannot interrupt anything. Only the app-server connection
        // can, so a session it is not carrying must not offer a Stop button
        // that the Mac would then have to refuse.
        guard session.observations?.contains(where: { $0.source == .appserver && $0.health.isHealthy }) == true else {
            return SessionActionSupport(intent: .stop,
                                        unsupportedReason: String(localized: "Your Mac isn't connected to Codex right now.", bundle: .module))
        }
        switch session.status {
        case .working:
            return SessionActionSupport(intent: .stop)
        case .done:
            return SessionActionSupport(intent: .stop,
                                        unsupportedReason: String(localized: "This task has already finished.", bundle: .module))
        case .needsResponse:
            return SessionActionSupport(intent: .stop,
                                        unsupportedReason: String(localized: "This task is waiting on you, not running.", bundle: .module))
        }
    }

    /// Cursor takes instructions, but never into the turn that is running.
    ///
    /// A supplement for a live turn is queued and handed to Cursor's own `stop`
    /// hook, which submits it as the next message — Cursor's documented
    /// auto-continuation, and the only remote write it offers. Continuing a
    /// finished conversation goes the other way: `cursor-agent --resume` opens
    /// the same chat in a terminal, so it needs the CLI to be installed and
    /// signed in, which only the Mac can know. Both require vibebuddy's hooks,
    /// so an unhooked Cursor session says so instead of promising delivery.
    private static func cursorSupport(intent: SessionActionIntent,
                                      session: AgentSession) -> SessionActionSupport {
        guard session.observations?.contains(where: { $0.source == .hook }) == true else {
            return SessionActionSupport(intent: intent,
                unsupportedReason: String(localized: "Install vibebuddy's Cursor hooks to send instructions from here.", bundle: .module))
        }
        switch intent {
        case .steer:
            return SessionActionSupport(intent: intent,
                note: String(localized: "Cursor can't be interrupted mid-turn. This is queued and sent the moment the turn ends.", bundle: .module))
        case .continue:
            return SessionActionSupport(intent: intent,
                note: String(localized: "Continues this chat in a terminal with the Cursor CLI.", bundle: .module))
        default:
            return SessionActionSupport(intent: intent)
        }
    }

    private static func stopUnsupportedReason(for agent: AgentKind) -> String {
        if agent == .cursor {
            // Cursor exposes no interrupt: not on its hooks, not on the CLI.
            return String(localized: "Stop this in Cursor on your Mac.", bundle: .module)
        }
        if agent == .claudeCode {
            // No official remote interrupt contract; a tmux Escape is not one.
            return String(localized: "Stop this on your Mac.", bundle: .module)
        }
        if agent == .grokBot {
            return String(localized: "Respond in Grok Bot on your Mac. Remote instructions are unavailable.", bundle: .module)
        }
        return String(localized: "\(agent.displayName) sessions can't take instructions from the phone yet — use the terminal.", bundle: .module)
    }

    /// Shown before send: which Mac, project and agent will receive this.
    public static func targetCaption(macName: String?, session: AgentSession) -> String {
        targetCaption(macName: macName, project: session.project, agent: session.agent)
    }

    /// The same caption from the pieces a Watch actually holds. The wrist never
    /// receives an `AgentSession` — its projection carries the project, the
    /// agent and (since the wrist gained a send button) the Mac's own name — and
    /// "which Mac am I about to talk to" must read identically on both devices.
    public static func targetCaption(macName: String?, project: String, agent: AgentKind?) -> String {
        let mac = macName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let location = mac.isEmpty ? String(localized: "Mac", bundle: .module) : mac
        let named = project.trimmingCharacters(in: .whitespacesAndNewlines)
        let what = named.isEmpty ? String(localized: "Unknown project", bundle: .module) : named
        guard let agent else { return "\(location) · \(what)" }
        return "\(location) · \(what) · \(agent.shortName)"
    }
}

/// Client → daemon payload for `/answer`. `intent` and `requestID` are how
/// the daemon refuses an expired answer and ignores a duplicate tap.
///
/// A **stop** carries no text: it binds to the running turn through
/// `expectedStatusSince` (when the session entered `working`), which the
/// daemon requires and re-checks against the live snapshot.
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
        case .remoteAvailable: return String(localized: "Review and respond on your iPhone.", bundle: .module)
        case .watchApproval: return String(localized: "Approve or deny on your Watch.", bundle: .module)
        case .macNativePrompt: return String(localized: "Respond in the agent's own prompt on your Mac. Remote response is unavailable.", bundle: .module)
        case .macGrokBot: return String(localized: "Respond in Grok Bot on your Mac. Remote response is unavailable.", bundle: .module)
        case .unavailable: return String(localized: "This request can't be verified. Wait for an updated connection and request.", bundle: .module)
        }
    }
}
