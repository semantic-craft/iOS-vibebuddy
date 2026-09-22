import Foundation

/// What a tap on a mirrored notification asks the Watch app to do.
///
/// Apple routes a *foreground* notification action to the device it was
/// tapped on, and a *background* action to the device the notification was
/// sent to (the iPhone, for everything the wrist ever sees). The Watch app
/// therefore only ever hears about foreground actions, and every action the
/// iPhone registers is one (ADR-0033) — so a tap on the wrist's Approve is
/// answered by the wrist, through the same `WatchSessionActionRequest` path its
/// card buttons use, and its outcome is shown where the tap happened.
///
/// This is the whole decision, kept out of the notification-centre delegate so
/// it can be tested without a notification. The delegate hands over strings;
/// the store acts on the case.
public enum WatchNotificationResponseRoute: Equatable, Sendable {
    /// Open the session. The default tap, and every action that cannot act
    /// from here — the card then says why, with the buttons it can honestly
    /// offer.
    case open(sessionID: String)
    /// Approve or deny exactly this permission prompt. The approval id came
    /// with the notification, and the store re-checks it against the relayed
    /// state before anything is sent.
    case decide(sessionID: String, approvalID: String, choice: WatchApprovalChoice)
    /// Answer the session's question with the dictated text. Bound to the
    /// question the relayed state holds *now*; a stale one is refused on the
    /// card rather than re-pointed.
    case answer(sessionID: String, text: String)
    /// Nothing to do: the notification was dismissed, or named no session.
    case ignore

    /// The session every route except `ignore` is about.
    public var sessionID: String? {
        switch self {
        case .open(let id), .decide(let id, _, _), .answer(let id, _): return id
        case .ignore: return nil
        }
    }

    /// Whether this route asks the store to *act*, not just to show.
    public var isAction: Bool {
        switch self {
        case .decide, .answer: return true
        case .open, .ignore: return false
        }
    }

    /// Map one notification response to a route.
    ///
    /// - `action`: the tapped button, or `nil` for the default tap (the body of
    ///   the notification) and for the system dismiss action.
    /// - `isDismiss`: the system's dismiss action, which is not a request.
    /// - `sessionID` / `approvalID`: the notification's `userInfo`, which is
    ///   data — only these two keys are read, and the store re-derives
    ///   everything else from the relayed state.
    /// - `userText`: the dictated reply, when the button collected one.
    public static func resolve(action: NotificationActionID?,
                               isDismiss: Bool,
                               sessionID: String?,
                               approvalID: String?,
                               userText: String?) -> WatchNotificationResponseRoute {
        guard !isDismiss else { return .ignore }
        guard let sessionID = trimmed(sessionID) else { return .ignore }
        switch action {
        case nil:
            return .open(sessionID: sessionID)
        case .approve, .deny:
            // No approval id means the cue was posted without one (a reminder,
            // or an older phone). Nothing to bind a decision to: open instead.
            guard let approvalID = trimmed(approvalID) else { return .open(sessionID: sessionID) }
            return .decide(sessionID: sessionID, approvalID: approvalID,
                           choice: action == .approve ? .allow : .deny)
        case .answer:
            guard let text = trimmed(userText) else { return .open(sessionID: sessionID) }
            return .answer(sessionID: sessionID, text: text)
        }
    }

    private static func trimmed(_ value: String?) -> String? {
        guard let value else { return nil }
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? nil : clean
    }
}

/// A banner button's decision while the store waits for the state and the
/// link that can carry it.
///
/// A foreground action can cold-launch the Watch app: the relayed state is
/// read back from disk at once, but WatchConnectivity activates and reports the
/// phone reachable a moment later. The action is held across that moment and
/// no longer — a tap is a decision about the request on screen *now*, and a
/// decision that waits a minute for a link is a decision about whatever is
/// pending by then.
public struct WatchBannerAction: Equatable, Sendable {
    /// How long a held action waits for the state and the link before the card
    /// says why it was not sent. Long enough for a cold launch to activate the
    /// session and hear the phone; short enough that nobody has walked away.
    public static let patience: TimeInterval = 8

    public var route: WatchNotificationResponseRoute
    public var heldAt: Date
    /// The newest relay revision this hold is known to have seen, and with it
    /// the only evidence that can say the request is gone. Nil until the hold's
    /// first state arrives.
    public private(set) var baselineRevision: UInt64?

    public init(route: WatchNotificationResponseRoute, heldAt: Date = Date(),
                baselineRevision: UInt64? = nil) {
        self.route = route
        self.heldAt = heldAt
        self.baselineRevision = baselineRevision
    }

    /// Note a state the wrist has just installed. The first one of a hold sets
    /// the baseline and proves nothing by itself; the baseline never moves
    /// after that, because it is the mark everything later is measured against.
    public mutating func noteInstalled(revision: UInt64) {
        if baselineRevision == nil { baselineRevision = revision }
    }

    /// Whether a state that does not hold the tapped request proves the request
    /// is gone.
    ///
    /// Only a *newer* relay revision is that proof, and only from a state worth
    /// measuring — the caller establishes that the payload came over the link
    /// from a connected relay before asking. The iPhone re-sends the context it
    /// already sent (`WatchStateInbox.accept` takes an equal revision back when
    /// source, epoch and `observedAt` match, which is exactly what activation
    /// does moments after a cold launch), so "a payload arrived after the tap"
    /// says nothing about whether the approval was ever in it. Reading it as
    /// proof abandoned the Approve this whole path exists to deliver: the wrist
    /// is holding yesterday's context *because* the approval is newer than
    /// anything it has.
    ///
    /// Running out of patience is not proof either — it means the wrist never
    /// found out, which is a different sentence and the caller's to choose.
    public func provesRequestGone(currentRevision: UInt64?) -> Bool {
        guard let baselineRevision, let currentRevision else { return false }
        return currentRevision > baselineRevision
    }
}

/// Why a banner action was *not* sent from the wrist, in words the card shows
/// above the buttons it still offers. Every case leaves the person looking at
/// the request with a live way forward — never a silent drop.
public enum WatchBannerActionFallback: String, Equatable, Sendable, CaseIterable {
    /// The relayed state does not hold this approval or question any more.
    case noLongerWaiting
    /// The relayed state holds it, but not in a form the wrist may decide —
    /// an Edit's diff, an over-long command, a multi-part question.
    case notDecidableHere
    /// The iPhone is out of range, or the iPhone has lost the Mac: the
    /// message could not have travelled.
    case linkDown
    /// Another action from this Watch is still in flight.
    case busy
    /// The state that would place this session never arrived in time.
    case noState
}

extension WatchHaptics {
    /// The tap the wrist gives when an action it sent comes to rest.
    ///
    /// One short tap when the Mac took it (the same beat as a result), two
    /// long ones when it did not — failed, refused, or lost, which all mean
    /// "look at the card". Nothing while it is still travelling: `sending` is a
    /// spinner, not news. Same vocabulary as the arrival cues, so a wrist that
    /// has learned two rhythms already knows these.
    public static func actionOutcome(_ phase: WatchSessionActionAttempt.Phase) -> [WristHapticBeat] {
        switch phase {
        case .sending: return []
        case .awaitingResolution: return beats(for: .done)
        case .failed, .unknown, .refused: return beats(for: .error)
        }
    }
}
