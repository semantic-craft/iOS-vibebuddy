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
            return SessionActionSupport(intent: intent, unsupportedReason: String(localized: "Respond in Grok Bot on your Mac. Remote instructions are unavailable."))
        }
        if session.status == .needsResponse {
            let handling = WaitHandling.resolve(for: session)
            let canAnswer = handling == .remoteAvailable && session.waitKind == .question
            return SessionActionSupport(intent: .answer, unsupportedReason: canAnswer ? nil :
                (handling == .remoteAvailable ? WaitHandling.macNativePrompt.message : handling.message))
        }
        let intent: SessionActionIntent = session.status == .done ? .continue : .steer
        // The channel decides first, the agent second: the same Cursor chat is
        // supplemented one way through its hooks, another through a hosted
        // ACP process, and not at all from a transcript tail.
        switch ControlChannel.infer(for: session) {
        case .some(.acp): return acpSupport(intent: intent)
        case .some(.cloud): return cloudSupport(intent: intent)
        case .some(.hook) where session.agent == .cursor: return cursorHookSupport(intent: intent)
        case .some(.none) where session.agent == .cursor: return unreachableCursorSupport(intent: intent, session: session)
        default: break
        }
        guard session.agent == .codex else {
            return SessionActionSupport(
                intent: intent,
                unsupportedReason: String(localized: "\(session.agent.displayName) sessions can't take instructions from the phone yet — use the terminal."))
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
        // Channels that carry a real interrupt: Codex's app-server
        // (`turn/interrupt`), a hosted Cursor CLI (`session/cancel`) and a Cursor
        // cloud run (`POST …/cancel`). Everything else is stopped where it runs.
        let channel = ControlChannel.infer(for: session)
        if session.agent == .cursor, channel == ControlChannel.none, Self.isCursorCloudAgent(session) {
            return SessionActionSupport(intent: .stop,
                unsupportedReason: String(localized: "Add a Cursor API key on your Mac to reach cloud agents from here."))
        }
        guard channel == .acp || channel == .cloud || session.agent == .codex else {
            return SessionActionSupport(intent: .stop, unsupportedReason: stopUnsupportedReason(for: session.agent))
        }
        // A Codex session is visible through the rollout tailer and hooks too,
        // and those cannot interrupt anything. Only the app-server connection
        // can, so a session it is not carrying must not offer a Stop button
        // that the Mac would then have to refuse.
        if session.agent == .codex,
           session.observations?.contains(where: { $0.source == .appserver && $0.health.isHealthy }) != true {
            return SessionActionSupport(intent: .stop,
                                        unsupportedReason: String(localized: "Your Mac isn't connected to Codex right now."))
        }
        switch session.status {
        case .working:
            return SessionActionSupport(intent: .stop)
        case .done:
            return SessionActionSupport(intent: .stop,
                                        unsupportedReason: String(localized: "This task has already finished."))
        case .needsResponse:
            return SessionActionSupport(intent: .stop,
                                        unsupportedReason: String(localized: "This task is waiting on you, not running."))
        }
    }

    /// A Cursor chat reached through its hooks takes instructions, but never
    /// into the turn that is running.
    ///
    /// A supplement for a live turn is queued and handed to Cursor's own `stop`
    /// hook, which submits it as the next message — Cursor's documented
    /// auto-continuation, and the only remote write the hooks offer. Continuing
    /// a finished conversation goes the other way: `cursor-agent --resume` opens
    /// the same chat in a terminal, so it needs the CLI to be installed and
    /// signed in, which only the Mac can know.
    private static func cursorHookSupport(intent: SessionActionIntent) -> SessionActionSupport {
        switch intent {
        case .steer:
            return SessionActionSupport(intent: intent,
                note: String(localized: "Cursor can't be interrupted mid-turn. This is queued and sent the moment the turn ends."))
        case .continue:
            return SessionActionSupport(intent: intent,
                note: String(localized: "Continues this chat in a terminal with the Cursor CLI."))
        default:
            return SessionActionSupport(intent: intent)
        }
    }

    /// A Cursor conversation vibebuddy can only see — a transcript tail, a
    /// database row — says so instead of promising delivery. A cloud agent
    /// without an API key is the same shape with a different fix.
    private static func unreachableCursorSupport(intent: SessionActionIntent,
                                                 session: AgentSession) -> SessionActionSupport {
        if isCursorCloudAgent(session) {
            return SessionActionSupport(intent: intent,
                unsupportedReason: String(localized: "Add a Cursor API key on your Mac to reach cloud agents from here."))
        }
        return SessionActionSupport(intent: intent,
            unsupportedReason: String(localized: "Install vibebuddy's Cursor hooks to send instructions from here."))
    }

    /// A `cursor-agent` vibebuddy hosts over ACP takes every instruction, but
    /// the protocol has no mid-turn steer: `session/prompt` is sequential, so a
    /// supplement waits for the running prompt to return and is sent as the
    /// next one. The composer says so, the same way it does for the hooks.
    private static func acpSupport(intent: SessionActionIntent) -> SessionActionSupport {
        switch intent {
        case .steer:
            return SessionActionSupport(intent: intent,
                note: String(localized: "Sent as the next message when this turn ends. Cursor's CLI takes one message at a time."))
        case .continue:
            return SessionActionSupport(intent: intent,
                note: String(localized: "Continues this chat through the Cursor CLI vibebuddy is running."))
        default:
            return SessionActionSupport(intent: intent)
        }
    }

    /// A Cursor cloud agent runs one run at a time: an idle agent takes a new
    /// run, a running one refuses a follow-up with `409 agent_busy`, so the
    /// refusal is made here rather than discovered on the wire.
    private static func cloudSupport(intent: SessionActionIntent) -> SessionActionSupport {
        switch intent {
        case .steer:
            return SessionActionSupport(intent: intent,
                unsupportedReason: String(localized: "This cloud agent is busy. Cursor takes a follow-up once the run finishes."))
        case .continue:
            return SessionActionSupport(intent: intent,
                note: String(localized: "Starts a new run on Cursor's cloud agent."))
        default:
            return SessionActionSupport(intent: intent)
        }
    }

    /// A Cursor conversation that runs on Cursor's machines rather than this
    /// Mac. Cursor gives cloud agents a `bc-`-prefixed id and uses it as the
    /// agent id in its own Cloud Agents API, so the id is the whole test — no
    /// extra field has to be kept in sync across the wire.
    public static func isCursorCloudAgent(_ session: AgentSession) -> Bool {
        session.agent == .cursor && session.id.hasPrefix("bc-")
    }

    private static func stopUnsupportedReason(for agent: AgentKind) -> String {
        if agent == .cursor {
            // A Cursor chat in the IDE exposes no interrupt on its hooks; only a
            // CLI vibebuddy hosts over ACP or a cloud run can be stopped, and
            // those never reach this line.
            return String(localized: "Stop this in Cursor on your Mac.")
        }
        if agent == .claudeCode {
            // No official remote interrupt contract; a tmux Escape is not one.
            return String(localized: "Stop this on your Mac.")
        }
        if agent == .grokBot {
            return String(localized: "Respond in Grok Bot on your Mac. Remote instructions are unavailable.")
        }
        return String(localized: "\(agent.displayName) sessions can't take instructions from the phone yet — use the terminal.")
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
        let location = mac.isEmpty ? String(localized: "Mac") : mac
        let named = project.trimmingCharacters(in: .whitespacesAndNewlines)
        let what = named.isEmpty ? String(localized: "Unknown project") : named
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
        case .remoteAvailable: return String(localized: "Review and respond on your iPhone.")
        case .watchApproval: return String(localized: "Approve or deny on your Watch.")
        case .macNativePrompt: return String(localized: "Respond in the agent's own prompt on your Mac. Remote response is unavailable.")
        case .macGrokBot: return String(localized: "Respond in Grok Bot on your Mac. Remote response is unavailable.")
        case .unavailable: return String(localized: "This request can't be verified. Wait for an updated connection and request.")
        }
    }
}
