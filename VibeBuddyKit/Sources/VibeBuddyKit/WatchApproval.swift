import Foundation

/// One action from the wrist, and everything the Watch is allowed to claim
/// happened to it.
///
/// The Watch holds no bearer token, opens no socket, and knows no host: it can
/// only ask the paired iPhone to act on something it has already been shown.
/// This file is the whole grammar of that ask — what may be said, who decides
/// whether it is still true, and what may be reported back.
///
/// Three actions travel this one path — approve/deny a permission, answer a
/// question, end a running turn — because they raise exactly the same three
/// questions, and answering them in three places is how the answers drift
/// apart. Four rules shape it, and each one is enforced by a type rather than
/// by a check at the call site:
///
/// 1. **Only one-shot.** `WatchApprovalChoice` has two cases. `alwaysAllow` and
///    `allowSession` (ADR-0010) are not representable, so no Watch payload —
///    honest, malformed, or replayed — can persist a permission rule.
/// 2. **Only what can be read.** `WatchApprovalEligibility` decides whether an
///    approval carries enough detail to be decided on a 40mm screen, and
///    `WatchStopOffer` decides whether a turn can be ended from here at all.
///    The same rules run in the projection (should the button exist?) and again
///    on the iPhone (should this action be honoured?), so the Watch's copy of
///    the world is never the authority.
/// 3. **Only what it was aimed at.** Every action names the thing in the world
///    it is bound to — an approval its id, an answer its question, a stop the
///    moment the turn began. A tap that arrives late is refused, never
///    re-pointed at whatever is pending now.
/// 4. **Only the truth about delivery.** `WatchSessionActionOutcome` separates
///    the Mac accepting an action from the iPhone refusing to send one from the
///    network losing it, so the wrist never says "stopped" because a tap felt
///    like it worked.

// MARK: - What the Watch may ask for

/// The only two decisions the wrist can make on a permission. Deliberately
/// *not* `ApprovalDecision`: that enum can also say `alwaysAllow` /
/// `allowSession`, which persist a rule beyond this one prompt and must be made
/// where the full command and its consequences are readable.
public enum WatchApprovalChoice: String, Codable, Sendable, CaseIterable {
    case allow
    case deny

    /// The wire decision this becomes on the Mac's `/decision` route.
    public var decision: ApprovalDecision { self == .allow ? .allow : .deny }
}

/// What one tap is for, and the identity it is bound to.
///
/// The payload of each case is that binding, not a convenience: it is what lets
/// the iPhone re-check the tap against a world that has moved on since the
/// Watch drew the screen.
public enum WatchSessionAction: Codable, Equatable, Sendable {
    /// Resolve this exact permission prompt.
    case approval(id: String, choice: WatchApprovalChoice)
    /// Answer this exact question. The Watch UI for it is ticket 03; the
    /// contract is here so both sides speak one grammar.
    case answer(pendingId: String, text: String)
    /// End the turn that began at this moment. A stop carries no text, and
    /// `statusSince` is the only thing standing between a stale tap and the
    /// next turn.
    case stop(statusSince: Date)

    /// Whether the action ends work rather than unblocking it. Destructive
    /// actions are drawn in red and confirmed twice on the wrist.
    public var isDestructive: Bool {
        if case .stop = self { return true }
        return false
    }
}

/// One tap, addressed to one session.
///
/// `attemptId` identifies the *tap*; the action identifies what it is *for*.
/// The pair is what makes a replay harmless: the attempt is deduplicated, and
/// the action's binding is re-checked against the live session, so a message
/// that arrives late cannot act on whatever happens to be true now.
public struct WatchSessionActionRequest: Codable, Equatable, Sendable {
    /// The WatchConnectivity message key both sides agree on.
    public static let messageKey = "vibebuddy.watchSessionAction"

    public var attemptId: String
    public var sessionId: String
    public var action: WatchSessionAction

    public init(attemptId: String, sessionId: String, action: WatchSessionAction) {
        self.attemptId = attemptId
        self.sessionId = sessionId
        self.action = action
    }
}

// MARK: - What the iPhone answers

/// What actually happened to a tap. Three outcomes, because collapsing them
/// would let the Watch imply an action landed when it did not.
public enum WatchSessionActionOutcome: String, Codable, Sendable {
    /// The Mac accepted it. Nothing is yet *known* to have happened — only a
    /// later snapshot can say the prompt resolved or the turn ended.
    case accepted
    /// The iPhone would not send it: the session is no longer in the state the
    /// action needs, the identity no longer matches, this agent cannot be asked
    /// this from a wrist, or the payload could not be read.
    case refused
    /// The iPhone could not deliver it to the Mac, or the Mac could not carry
    /// it out. The tap can be made again.
    case failed
    /// The iPhone sent it and never learned what became of it — the Mac's reply
    /// was lost, not its answer. The far link is where this usually happens: a
    /// `/answer` the Mac accepted and acted on, whose 200 never came back.
    /// Distinct from `failed` because "that didn't send" is the one thing
    /// nobody here can honestly say, and because it must not invite a retry.
    case unknown
}

public struct WatchSessionActionResult: Codable, Equatable, Sendable {
    /// The WatchConnectivity reply key both sides agree on.
    public static let messageKey = "vibebuddy.watchSessionActionResult"

    public var attemptId: String
    public var outcome: WatchSessionActionOutcome

    public init(attemptId: String, outcome: WatchSessionActionOutcome) {
        self.attemptId = attemptId
        self.outcome = outcome
    }
}

// MARK: - The approval-only wire form an older Watch still speaks

/// A watchOS app updates on its own schedule, so an iPhone that has already
/// taken this release can be handed a tap from a Watch that has not. These two
/// types are that older Watch's vocabulary, kept so its Approve button keeps
/// working through the update window; nothing in this release sends them.
public struct WatchApprovalRequest: Codable, Equatable, Sendable {
    public static let messageKey = "vibebuddy.watchApproval"

    public var attemptId: String
    public var sessionId: String
    public var approvalId: String
    public var choice: WatchApprovalChoice

    public init(attemptId: String, sessionId: String, approvalId: String, choice: WatchApprovalChoice) {
        self.attemptId = attemptId
        self.sessionId = sessionId
        self.approvalId = approvalId
        self.choice = choice
    }

    /// The same tap in the one vocabulary the iPhone judges taps in.
    public var sessionAction: WatchSessionActionRequest {
        WatchSessionActionRequest(attemptId: attemptId, sessionId: sessionId,
                                  action: .approval(id: approvalId, choice: choice))
    }
}

public struct WatchApprovalResult: Codable, Equatable, Sendable {
    public static let messageKey = "vibebuddy.watchApprovalResult"

    public var attemptId: String
    public var outcome: WatchSessionActionOutcome

    public init(attemptId: String, outcome: WatchSessionActionOutcome) {
        self.attemptId = attemptId
        self.outcome = outcome
    }

    public init(_ result: WatchSessionActionResult) {
        self.init(attemptId: result.attemptId, outcome: result.outcome)
    }
}

// MARK: - Which approvals may be decided from the wrist

/// The single rule for "is there enough here to decide on?", used by the
/// projection that builds the Watch's alerts and again by the iPhone that
/// receives its taps.
///
/// It is deliberately conservative. A wrist gets one line of context, so an
/// approval qualifies only when it names a tool, a project, and a *literal*
/// target — the exact command or the exact path — short enough to be read in
/// full. Anything carrying an Edit/Write pre- or post-image is display-only: the
/// diff is what the decision is about and it never reaches the Watch, so the
/// phone is offered only when the shared capability confirms it can respond.
public enum WatchApprovalEligibility {
    /// The longest command or path a wrist can be asked to read before deciding.
    /// Past this the text truncates or shrinks past legibility, and an approval
    /// nobody can finish reading is not an informed one.
    public static let maxDetailLength = 160

    /// The approval this session can resolve from the Watch, or `nil` when it
    /// cannot be decided here. WaitHandling determines the destination.
    public static func approvalId(for session: AgentSession) -> String? {
        guard let approval = ApprovalEligibility.approval(for: session),
              !session.project.isEmpty,
              !approval.tool.isEmpty,
              // A truncated preview is a label, not the thing being approved.
              let detail = approval.command ?? approval.filePath,
              !detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              detail.count <= maxDetailLength,
              // The diff is the decision, and the Watch is never sent it.
              approval.oldText == nil, approval.newText == nil
        else { return nil }
        return approval.id
    }
}

// MARK: - The iPhone's gate

/// The iPhone's decision about a tap that arrived from the wrist.
///
/// The Watch's screen is a memory of a snapshot; this runs against the sessions
/// the phone holds *now*, which is the only copy that was ever authenticated.
public struct WatchSessionActionGate: Equatable, Sendable {
    public enum Resolution: Equatable, Sendable {
        /// Forward this to the Mac's `/decision`.
        case decide(approvalId: String, decision: ApprovalDecision)
        /// Forward this to the Mac's `/answer` as an answer.
        case answer(pendingId: String, text: String)
        /// Forward this to the Mac's `/answer` as `intent: stop`, carrying the
        /// same `statusSince` the daemon will re-check for itself.
        case stop(statusSince: Date)
        /// This exact tap was already forwarded and accepted; say so again
        /// rather than sending it twice.
        case duplicate
        /// Do not act: the world moved on, or this was never actionable.
        case refused
    }

    /// How many recent taps are remembered. A tap is a human gesture, so a
    /// handful is generous; the bound keeps a long-lived phone from growing a
    /// list nobody reads.
    public static let historyLimit = 32

    /// The tolerance for matching a relayed `statusSince` against the live one.
    /// The value crosses two JSON hops as a double, so it round-trips exactly;
    /// this is the same millisecond guard the daemon applies, not a licence to
    /// aim a stop at a nearby turn.
    public static let statusSinceTolerance: TimeInterval = 0.001

    private var handled: [String] = []

    public init() {}

    /// Whether this tap may be forwarded, judged against the live sessions.
    public func admit(_ request: WatchSessionActionRequest, sessions: [AgentSession]) -> Resolution {
        if handled.contains(request.attemptId) { return .duplicate }
        guard let session = sessions.first(where: { $0.id == request.sessionId }) else { return .refused }
        switch request.action {
        case .approval(let id, let choice):
            guard let approvalId = WatchApprovalEligibility.approvalId(for: session),
                  approvalId == id else { return .refused }
            return .decide(approvalId: approvalId, decision: choice.decision)
        case .answer(let pendingId, let text):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  WaitHandling.resolve(for: session) == .remoteAvailable,
                  session.waitKind == .question,
                  let question = session.pendingQuestion,
                  // One string finishes a one-part question and nothing else.
                  // The projection already withholds the identity for the rest;
                  // this is the same rule run against the live session, so a
                  // forged payload cannot half-answer a three-part prompt.
                  question.isSinglePart,
                  question.id == pendingId else { return .refused }
            return .answer(pendingId: pendingId, text: trimmed)
        case .stop(let statusSince):
            // The agent rule and the running-turn rule are the same ones the
            // daemon applies; running them here means a stop the Mac would
            // refuse never leaves the phone.
            guard SessionActionSupport.resolveStop(for: session).isAvailable,
                  abs(session.statusSince.timeIntervalSince1970
                      - statusSince.timeIntervalSince1970) < Self.statusSinceTolerance
            else { return .refused }
            return .stop(statusSince: statusSince)
        }
    }

    /// Remember a tap the Mac accepted. Recorded only on success, so a tap lost
    /// to a dropped network can be made again.
    public mutating func commit(_ attemptId: String) {
        guard !handled.contains(attemptId) else { return }
        handled.append(attemptId)
        if handled.count > Self.historyLimit {
            handled.removeFirst(handled.count - Self.historyLimit)
        }
    }
}

// MARK: - The Watch's action state

/// What the wrist is allowed to show about a tap in flight.
public struct WatchSessionActionAttempt: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        /// Handed to WatchConnectivity, no reply yet.
        case sending
        /// The Mac took it. The button stays until a snapshot confirms.
        case awaitingResolution
        /// It never reached the Mac. Offer the tap again.
        case failed
        /// It left the wrist and no answer ever came back. Different from
        /// `failed` in the only way that matters: nobody knows whether the Mac
        /// acted. Nothing is resent for it — a lost receipt is a reason to look,
        /// not a reason to send a second time.
        case unknown
        /// The iPhone would not act on it.
        case refused
    }

    public var attemptId: String
    public var sessionId: String
    public var action: WatchSessionAction
    public var phase: Phase

    /// The approval this attempt is about, when it is about one — so an
    /// approval card can tell "my attempt" from a stop on the same session.
    public var approvalId: String? {
        if case .approval(let id, _) = action { return id }
        return nil
    }

    /// The question this attempt answers, when it answers one. One card can
    /// carry an approval, an answer and a stop; each control needs to know
    /// whether the attempt in flight is the one it drew.
    public var pendingId: String? {
        if case .answer(let id, _) = action { return id }
        return nil
    }

    /// The text on its way to the agent, when there is any. Shown so the wrist
    /// can say *what* it is sending while it is still in flight.
    public var answerText: String? {
        if case .answer(_, let text) = action { return text }
        return nil
    }

    public var isStop: Bool { action.isDestructive }
}

/// The Watch's action surface, as a value: one attempt at a time, and every
/// transition it is allowed to make.
///
/// Keeping it here rather than in the view means "a second tap does not send a
/// second decision" and "the button stays until the Mac says it is gone" are
/// tested without a paired device. One attempt per Watch, not per session: a
/// wrist shows one thing at a time, and a person cannot be tapping two screens.
public struct WatchSessionActionState: Equatable, Sendable {
    public private(set) var action: WatchSessionActionAttempt?

    public init() {}

    /// An action is on its way and the buttons must not fire again.
    public var isBusy: Bool {
        switch action?.phase {
        case .sending, .awaitingResolution: return true
        case .failed, .unknown, .refused, nil: return false
        }
    }

    /// Start a decision on this alert. Returns the message to send, or `nil`
    /// when the alert cannot be decided from the wrist or an attempt is already
    /// in flight — which is what makes repeated taps harmless.
    public mutating func begin(
        alert: WatchAlert,
        choice: WatchApprovalChoice,
        attemptId: String
    ) -> WatchSessionActionRequest? {
        guard alert.isDecidable, let approvalId = alert.approvalId else { return nil }
        return begin(sessionId: alert.sessionId,
                     action: .approval(id: approvalId, choice: choice),
                     attemptId: attemptId)
    }

    /// Start an answer to this alert's question. The wrist UI that calls it is
    /// ticket 03; the transition it makes is the same one every action makes.
    public mutating func begin(
        alert: WatchAlert,
        answer text: String,
        attemptId: String
    ) -> WatchSessionActionRequest? {
        guard alert.isAnswerable, let pendingId = alert.pendingId,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return begin(sessionId: alert.sessionId,
                     action: .answer(pendingId: pendingId, text: text),
                     attemptId: attemptId)
    }

    /// Start a stop on this running task. It is bound to the turn the wrist was
    /// looking at: `statusSince` is when that turn began, and the daemon
    /// refuses the stop rather than moving it onto a later one.
    public mutating func begin(
        stop task: WatchFollowedTask,
        attemptId: String
    ) -> WatchSessionActionRequest? {
        guard task.stop?.isOffered == true else { return nil }
        return begin(sessionId: task.sessionID,
                     action: .stop(statusSince: task.statusSince),
                     attemptId: attemptId)
    }

    private mutating func begin(sessionId: String,
                                action: WatchSessionAction,
                                attemptId: String) -> WatchSessionActionRequest? {
        guard !isBusy else { return nil }
        self.action = WatchSessionActionAttempt(attemptId: attemptId, sessionId: sessionId,
                                                action: action, phase: .sending)
        return WatchSessionActionRequest(attemptId: attemptId, sessionId: sessionId, action: action)
    }

    /// The iPhone answered. A reply for an attempt we are no longer showing is
    /// ignored rather than allowed to overwrite a newer one, and an attempt
    /// that already has its answer keeps it: a late "couldn't send that" landing
    /// on top of "this is no longer running" would invite a second stop at the
    /// one moment a stop is most likely to hit the wrong turn.
    public mutating func apply(_ result: WatchSessionActionResult) {
        guard var current = action, current.attemptId == result.attemptId,
              current.phase == .sending else { return }
        switch result.outcome {
        case .accepted: current.phase = .awaitingResolution
        case .refused: current.phase = .refused
        case .failed: current.phase = .failed
        case .unknown: current.phase = .unknown
        }
        action = current
    }

    /// The tap never left the wrist: no link, nothing encodable, nothing sent.
    /// The Mac cannot have acted, so this one may plainly be tried again.
    public mutating func fail(attemptId: String) {
        apply(WatchSessionActionResult(attemptId: attemptId, outcome: .failed))
    }

    /// The message went out and the receipt was lost — no reply, or one that
    /// could not be read.
    ///
    /// It is a separate ending from `fail` because it supports a different
    /// sentence: "that didn't send" is a claim this Watch cannot make once the
    /// message is gone. Nothing is resent automatically; the wrist says it does
    /// not know, and the next snapshot settles it.
    public mutating func lost(attemptId: String) {
        guard var current = action, current.attemptId == attemptId,
              current.phase == .sending else { return }
        current.phase = .unknown
        action = current
    }

    /// A new state arrived from the iPhone. The attempt clears only when the
    /// thing it named is no longer there to act on — an accepted delivery is
    /// not a resolution, and the Mac is the only thing that can confirm one.
    ///
    /// This is also the only thing that takes a button away. A stop that the
    /// Mac accepted keeps saying so until a snapshot shows the turn is over.
    public mutating func reconcile(with state: WatchDashboardState) {
        guard let current = action else { return }
        let stillThere: Bool
        switch current.action {
        case .approval(let id, _):
            stillThere = state.alerts.contains { $0.isDecidable && $0.approvalId == id }
        case .answer(let pendingId, _):
            stillThere = state.alerts.contains {
                $0.sessionId == current.sessionId && $0.isAnswerable && $0.pendingId == pendingId
            }
        case .stop(let statusSince):
            stillThere = state.followedTasks.contains {
                $0.sessionID == current.sessionId && $0.stop?.isOffered == true
                    && abs($0.statusSince.timeIntervalSince1970
                           - statusSince.timeIntervalSince1970) < WatchSessionActionGate.statusSinceTolerance
            }
        }
        if !stillThere { action = nil }
    }

    /// The user swiped away from the screen or dismissed a failure.
    public mutating func clear() { action = nil }
}
