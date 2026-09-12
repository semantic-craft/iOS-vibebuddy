import Foundation

/// Whether this session's running turn can be ended from the wrist.
///
/// Derived on the iPhone from the shared `SessionActionSupport` rule and only
/// displayed on the Watch, the same way `WaitHandling` is: the wrist must never
/// be the thing that decides an agent can be interrupted.
///
/// Absent (`nil`) is the third answer and the common one — this session is not
/// running a turn, so there is nothing to end and nothing to say about ending
/// it. A relay predating this contract is also absent, which reads the same
/// way: no button, no explanation, no claim.
public enum WatchStopOffer: Codable, Equatable, Sendable {
    /// A running turn this Watch may end, after a second confirmation.
    case offered
    /// A running turn that cannot be ended from here, and why not — shown in
    /// the button's place, because a button that does nothing is worse than a
    /// sentence saying where to go instead.
    case blocked(WatchStopBlock)

    public var isOffered: Bool { self == .offered }

    public var block: WatchStopBlock? {
        if case .blocked(let block) = self { return block }
        return nil
    }

    /// The rule, run against one session. Only a `working` session has a turn
    /// to end; `done` and `needsResponse` say nothing rather than explaining an
    /// absence nobody asked about.
    public static func resolve(for session: AgentSession) -> WatchStopOffer? {
        guard session.status == .working else { return nil }
        guard !SessionActionSupport.resolveStop(for: session).isAvailable else { return .offered }
        return .blocked(WatchStopBlock(blocking: session))
    }
}

/// Why a running turn cannot be ended from the wrist, as a code rather than a
/// sentence.
///
/// The same choice `WaitHandling` makes, for the same reason: this value is
/// projected on the iPhone and rendered on the Watch, so a sentence resolved
/// here would arrive in the *phone's* language and freeze until the next relay.
/// The code travels; the words are chosen where they are read.
public enum WatchStopBlock: String, Codable, Equatable, Sendable {
    /// Claude Code — no official remote interrupt contract exists, so the Mac
    /// is where this ends (spec decision, 2026-09-08).
    case macOnly
    /// Grok, Grok Bot, Cursor and anything else that takes no remote
    /// instruction yet.
    case agentUnsupported
    /// Codex, but this Mac is not carrying the session on its app-server
    /// connection — the rollout tailer and hooks can see a turn, and neither
    /// can end one.
    case macNotConnected

    /// Derived from the session rather than from the daemon's wording, so the
    /// two can never drift into disagreeing. Only reached for a `working`
    /// session `resolveStop` refused, which leaves exactly these three causes.
    init(blocking session: AgentSession) {
        if session.agent == .claudeCode { self = .macOnly }
        else if session.agent != .codex { self = .agentUnsupported }
        else { self = .macNotConnected }
    }

    /// What to say in the button's place. `agent` names the one that cannot be
    /// asked, matching the wording every other remote-instruction refusal uses.
    public func message(agent: AgentKind?) -> String {
        switch self {
        case .macOnly:
            return String(localized: "Stop this on your Mac.", bundle: .module)
        case .macNotConnected:
            return String(localized: "Your Mac isn't connected to Codex right now.", bundle: .module)
        case .agentUnsupported:
            guard let agent else {
                return String(localized: "This agent can't take instructions from the phone yet — use the terminal.", bundle: .module)
            }
            if agent == .grokBot {
                return String(localized: "Respond in Grok Bot on your Mac. Remote instructions are unavailable.", bundle: .module)
            }
            return String(localized: "\(agent.displayName) sessions can't take instructions from the phone yet — use the terminal.", bundle: .module)
        }
    }
}

/// Only the display-safe facts needed to recognize a followed session.
public struct WatchFollowedTask: Codable, Equatable, Sendable, Identifiable {
    /// Absent in older relays/caches; never infer an agent from display text.
    public var agent: AgentKind?
    public var sessionID: String
    public var completionID: String?
    public var title: String
    public var summary: String?
    /// Bounded Mac-authored result for the detail screen, excluded from WidgetKit.
    public var detailSummary: String? = nil
    public var presentation: TaskPresentationState
    public var waitKind: WaitKind?
    public var pendingID: String?
    /// Whether the wrist may end this session's running turn, and why not when
    /// it may not. `nil` on an older relay or cache, which reads as "say
    /// nothing" — never as a Stop button.
    public var stop: WatchStopOffer?
    public var statusSince: Date
    public var id: String { sessionID }

    public init(_ session: AgentSession) {
        agent = session.agent
        sessionID = session.id
        completionID = session.completionID
        title = String(session.displayTitle.trimmingCharacters(in: .whitespacesAndNewlines).prefix(160))
        // A request can contain a full command, path or question. The compact
        // surface sends its category only; details stay in existing alert UI.
        let text = session.status == .needsResponse ? nil : session.displaySummary
        detailSummary = session.completionSummary
        summary = text.flatMap { raw in
            let line = raw.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
            // Conservative: do not place path/command-shaped summaries on a face.
            guard !line.contains("/"), !line.contains("\\"), !line.contains("`"),
                  !line.contains("$") else { return nil }
            return String(line.prefix(100))
        }
        // Explicit input wins over error on this surface (the PRD's proposed
        // default); retain the shared presentation vocabulary and color tokens.
        presentation = session.status == .needsResponse ? .requiresInput :
            TaskPresentationState.project(status: session.status, waitKind: session.waitKind,
                failed: session.failed == true, hasUnreadCompletion: session.hasUnreadCompletion)
        waitKind = session.status == .needsResponse
            ? (session.waitKind ?? (session.pendingApproval != nil ? .permission : .question)) : nil
        pendingID = session.pendingApproval?.id ?? session.pendingQuestion?.id
        stop = WatchStopOffer.resolve(for: session)
        statusSince = session.statusSince
    }

    public var sourceName: String { agent?.displayName ?? String(localized: "Unknown source", bundle: .module) }

    public var complicationTask: Self {
        var compact = self
        compact.detailSummary = nil
        // A complication is a glance, not a control surface: it offers no way
        // to stop anything, so it carries neither the offer nor its reason.
        compact.stop = nil
        return compact
    }

    public var isCandidate: Bool { presentation != .idle && presentation != .unassigned }
    private var rank: Int {
        switch presentation {
        case .requiresInput: 0
        case .error: 1
        case .completeUnread: 2
        case .thinking: 3
        default: 4
        }
    }

    public static func select(from tasks: [Self], keeping sessionID: String? = nil) -> Self? {
        let sorted = tasks.filter(\.isCandidate).sorted {
            if $0.rank != $1.rank { return $0.rank < $1.rank }
            if $0.statusSince != $1.statusSince { return $0.statusSince < $1.statusSince }
            return $0.sessionID < $1.sessionID
        }
        guard let first = sorted.first else { return nil }
        if first.presentation == .thinking,
           let retained = sorted.first(where: { $0.sessionID == sessionID && $0.presentation == .thinking }) {
            return retained
        }
        return first
    }
}

/// Separate from the app's richer alert cache: no full requests reach WidgetKit.
public struct WatchComplicationSnapshot: Codable, Equatable, Sendable {
    public var sourceID: String?
    public var pairingEpoch: String?
    public var tasks: [WatchFollowedTask]
    public var selectedSessionID: String?
    public var pendingCompletionIDs: [String] = []
    public var observedAt: Date
    public var relay: WatchRelayState
    public var selectedTask: WatchFollowedTask? {
        guard sourceID != nil else { return nil }
        return WatchFollowedTask.select(from: tasks, keeping: selectedSessionID)
    }
    public var otherCount: Int { max(0, tasks.filter(\.isCandidate).count - 1) }

    public init(state: WatchDashboardState, previous: Self? = nil) {
        sourceID = state.sourceID
        pairingEpoch = state.pairingEpoch
        tasks = state.followedTasks.map(\.complicationTask)
        observedAt = state.observedAt
        relay = state.relay
        let retained = previous?.sourceID == sourceID && previous?.pairingEpoch == pairingEpoch
            ? previous?.selectedSessionID : nil
        selectedSessionID = WatchFollowedTask.select(from: tasks, keeping: retained)?.sessionID
    }
}
