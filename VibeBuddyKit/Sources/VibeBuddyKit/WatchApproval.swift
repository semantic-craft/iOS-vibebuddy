import Foundation

/// One-shot approval from the wrist.
///
/// The Watch holds no bearer token, opens no socket, and knows no host: it can
/// only ask the paired iPhone to make a decision it has already been shown. This
/// file is the whole grammar of that ask — what may be said, who decides whether
/// it is still true, and what the Watch is allowed to claim happened.
///
/// Three rules shape it, and each one is enforced by a type rather than a check:
///
/// 1. **Only one-shot.** `WatchApprovalChoice` has two cases. `alwaysAllow` and
///    `allowSession` (ADR-0010) are not representable, so no Watch payload —
///    honest, malformed, or replayed — can persist a permission rule.
/// 2. **Only what can be read.** `WatchApprovalEligibility` decides whether an
///    approval carries enough detail to be decided on a 40mm screen. The same
///    rule runs in the projection (should the buttons exist?) and again on the
///    iPhone (should this action be honoured?), so the Watch's copy of the world
///    is never the authority.
/// 3. **Only the truth about delivery.** `WatchApprovalOutcome` separates the
///    Mac accepting a decision from the iPhone refusing to send one from the
///    network losing it, so the wrist never says "approved" because a tap felt
///    like it worked.

// MARK: - What the Watch may ask for

/// The only two decisions the wrist can make. Deliberately *not*
/// `ApprovalDecision`: that enum can also say `alwaysAllow` / `allowSession`,
/// which persist a rule beyond this one prompt and must be made where the full
/// command and its consequences are readable.
public enum WatchApprovalChoice: String, Codable, Sendable, CaseIterable {
    case allow
    case deny

    /// The wire decision this becomes on the Mac's `/decision` route.
    public var decision: ApprovalDecision { self == .allow ? .allow : .deny }
}

/// One tap, addressed to one approval.
///
/// `attemptId` identifies the *tap*; `approvalId` identifies the *prompt*. The
/// pair is what makes a replay harmless: the attempt is deduplicated, and the
/// approval id is re-checked against the live session, so a message that arrives
/// late cannot resolve whatever prompt happens to be pending now.
public struct WatchApprovalRequest: Codable, Equatable, Sendable {
    /// The WatchConnectivity message key both sides agree on.
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
}

// MARK: - What the iPhone answers

/// What actually happened to a tap. Three outcomes, because collapsing them
/// would let the Watch imply a decision landed when it did not.
public enum WatchApprovalOutcome: String, Codable, Sendable {
    /// The Mac accepted the decision. The prompt is not yet *known* to be
    /// resolved — only a later snapshot can say that.
    case accepted
    /// The iPhone would not send it: the session is no longer waiting, the
    /// approval id no longer matches, the detail is not decidable from a wrist,
    /// or the payload could not be read.
    case refused
    /// The iPhone could not deliver it to the Mac.
    case failed
}

public struct WatchApprovalResult: Codable, Equatable, Sendable {
    /// The WatchConnectivity reply key both sides agree on.
    public static let messageKey = "vibebuddy.watchApprovalResult"

    public var attemptId: String
    public var outcome: WatchApprovalOutcome

    public init(attemptId: String, outcome: WatchApprovalOutcome) {
        self.attemptId = attemptId
        self.outcome = outcome
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
/// only honest thing to offer is "review it on your iPhone".
public enum WatchApprovalEligibility {
    /// The longest command or path a wrist can be asked to read before deciding.
    /// Past this the text truncates or shrinks past legibility, and an approval
    /// nobody can finish reading is not an informed one.
    public static let maxDetailLength = 160

    /// The approval this session can resolve from the Watch, or `nil` when it
    /// must be reviewed on the iPhone.
    public static func approvalId(for session: AgentSession) -> String? {
        guard session.status == .needsResponse,
              session.waitKind == .permission,
              !session.project.isEmpty,
              let approval = session.pendingApproval,
              !approval.id.isEmpty,
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
public struct WatchApprovalGate: Equatable, Sendable {
    public enum Resolution: Equatable, Sendable {
        /// Forward this to the Mac's `/decision`.
        case send(approvalId: String, decision: ApprovalDecision)
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

    private var handled: [String] = []

    public init() {}

    /// Whether this tap may be forwarded, judged against the live sessions.
    public func admit(_ request: WatchApprovalRequest, sessions: [AgentSession]) -> Resolution {
        if handled.contains(request.attemptId) { return .duplicate }
        guard let session = sessions.first(where: { $0.id == request.sessionId }),
              let approvalId = WatchApprovalEligibility.approvalId(for: session),
              approvalId == request.approvalId
        else { return .refused }
        return .send(approvalId: approvalId, decision: request.choice.decision)
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
public struct WatchApprovalAction: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        /// Handed to WatchConnectivity, no reply yet.
        case sending
        /// The Mac took it. The alert stays up until a snapshot confirms.
        case awaitingResolution
        /// It never reached the Mac. Offer the tap again.
        case failed
        /// The iPhone would not act on it.
        case refused
    }

    public var attemptId: String
    public var approvalId: String
    public var choice: WatchApprovalChoice
    public var phase: Phase
}

/// The Watch's approval screen, as a value: one attempt at a time, and every
/// transition it is allowed to make.
///
/// Keeping it here rather than in the view means "a second tap does not send a
/// second decision" and "the alert stays until the Mac says it is gone" are
/// tested without a paired device.
public struct WatchApprovalActionState: Equatable, Sendable {
    public private(set) var action: WatchApprovalAction?

    public init() {}

    /// A decision is on its way and the buttons must not fire again.
    public var isBusy: Bool {
        switch action?.phase {
        case .sending, .awaitingResolution: return true
        case .failed, .refused, nil: return false
        }
    }

    /// Start an attempt on this alert. Returns the message to send, or `nil`
    /// when the alert cannot be decided from the wrist or an attempt is already
    /// in flight — which is what makes repeated taps harmless.
    public mutating func begin(
        alert: WatchAlert,
        choice: WatchApprovalChoice,
        attemptId: String
    ) -> WatchApprovalRequest? {
        guard let approvalId = alert.approvalId, !isBusy else { return nil }
        action = WatchApprovalAction(attemptId: attemptId, approvalId: approvalId,
                                     choice: choice, phase: .sending)
        return WatchApprovalRequest(attemptId: attemptId, sessionId: alert.sessionId,
                                    approvalId: approvalId, choice: choice)
    }

    /// The iPhone answered. A reply for an attempt we are no longer showing is
    /// ignored rather than allowed to overwrite a newer one.
    public mutating func apply(_ result: WatchApprovalResult) {
        guard var current = action, current.attemptId == result.attemptId else { return }
        switch result.outcome {
        case .accepted: current.phase = .awaitingResolution
        case .refused: current.phase = .refused
        case .failed: current.phase = .failed
        }
        action = current
    }

    /// The message never got a reply at all.
    public mutating func fail(attemptId: String) {
        apply(WatchApprovalResult(attemptId: attemptId, outcome: .failed))
    }

    /// A new state arrived from the iPhone. The attempt clears only when the
    /// approval it named is no longer pending — an accepted delivery is not a
    /// resolution, and the Mac is the only thing that can confirm one.
    public mutating func reconcile(with state: WatchDashboardState) {
        guard let current = action else { return }
        let stillPending = state.alerts.contains { $0.approvalId == current.approvalId }
        if !stillPending { action = nil }
    }

    /// The user swiped away from the alert or dismissed a failure.
    public mutating func clear() { action = nil }
}
