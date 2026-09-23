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
    /// Answer the question the notification was about with the dictated
    /// text. `questionID` came with the notification the way `approvalId`
    /// does, and binds the reply the moment it is held; nil for a cue posted
    /// without one (an older phone or Mac), which falls back to the first
    /// question a relayed state shows. A question that moved on is refused on
    /// the card rather than re-pointed.
    case answer(sessionID: String, questionID: String?, text: String)
    /// Nothing to do: the notification was dismissed, or named no session.
    case ignore

    /// The session every route except `ignore` is about.
    public var sessionID: String? {
        switch self {
        case .open(let id), .decide(let id, _, _), .answer(let id, _, _): return id
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
    /// - `sessionID` / `approvalID` / `questionID`: the notification's
    ///   `userInfo`, which is data — only these keys are read, and the store
    ///   re-derives everything else from the relayed state.
    /// - `userText`: the dictated reply, when the button collected one.
    public static func resolve(action: NotificationActionID?,
                               isDismiss: Bool,
                               sessionID: String?,
                               approvalID: String?,
                               questionID: String? = nil,
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
            return .answer(sessionID: sessionID, questionID: trimmed(questionID), text: text)
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
    /// The relay revision of the first *evidence* state this hold saw, and the
    /// mark every later one is measured against. Nil until that state arrives.
    ///
    /// Only the caller knows which states are evidence, so only the caller sets
    /// this, through `noteInstalled`. Seeding it from whatever happened to be on
    /// screen at the tap put yesterday's cached number here, and the first live
    /// snapshot then read as proof the request had ended.
    public private(set) var baselineRevision: UInt64?
    /// The question a held reply is bound to. Fixed at the hold when the
    /// notification named its question (`questionId`, since #248); otherwise
    /// the first time a relayed state showed the wrist an answerable question
    /// for this session. Nil for a decision, which carries its own binding in
    /// the tap.
    public private(set) var boundPendingID: String?

    public init(route: WatchNotificationResponseRoute, heldAt: Date = Date(),
                baselineRevision: UInt64? = nil) {
        self.route = route
        self.heldAt = heldAt
        self.baselineRevision = baselineRevision
        if case .answer(_, let questionID?, _) = route { boundPendingID = questionID }
    }

    /// Whether the question in front of the wrist is still the one these words
    /// were dictated for.
    ///
    /// A notification that names its question (`questionId`) is bound at the
    /// hold, and this only compares. One that does not — a cue from an older
    /// phone or Mac — is bound at the first sight of one instead: the first
    /// answerable question a *relayed* state holds for this session — and from
    /// then on the binding does not move. Without that, a hold waiting for the
    /// link would follow the session: the agent answers "Delete the database?"
    /// and asks "Ship the release?", the lookup matches the new question, the
    /// iPhone's gate accepts it because the id is live, and the "no" meant for
    /// the first is recorded against the second. The card's own dictation pins
    /// `pendingId` when the words are made (`WatchAnswerDraft`); this is the
    /// banner's version of that promise, and it is why the wrist may send one
    /// at all.
    ///
    /// Returns false for a question that is not the bound one, and for a state
    /// with no id to bind — neither is something to send into.
    public mutating func bindsAnswer(to pendingID: String?) -> Bool {
        guard let pendingID, !pendingID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return false }
        guard let boundPendingID else {
            self.boundPendingID = pendingID
            return true
        }
        return boundPendingID == pendingID
    }

    /// Where a reply's question stands among the alerts a state holds.
    public enum ReplyStanding: Equatable, Sendable {
        /// The session is asking the bound question (or, with nothing bound
        /// yet, a question with an id this reply may bind). The caller still
        /// checks it can be answered in one string.
        case asking(WatchAlert)
        /// The session is asking something that carries no id — a prompt part
        /// of which must be typed. The wrist cannot tell whether it is the
        /// bound question, and "decide it on your iPhone or Mac" is true of it
        /// either way.
        case unbindable(WatchAlert)
        /// The session is asking a *different* question. The agent moved on
        /// between the dictation and the send: refuse, never re-point.
        case replaced
        /// The session is asking nothing. Gone only if a newer revision says so.
        case absent
    }

    /// The pure decision behind a held reply and behind the sentence a refused
    /// one leaves: which alert, if any, these words may go to.
    public static func replyStanding(boundPendingID: String?, sessionID: String,
                                     alerts: [WatchAlert]) -> ReplyStanding {
        let bound = boundPendingID.flatMap(nonBlank)
        if let bound, let exact = alerts.first(where: {
            $0.sessionId == sessionID && $0.pendingId == bound
        }) { return .asking(exact) }
        guard let asking = alerts.first(where: {
            $0.sessionId == sessionID && $0.waitKind == .question
        }) else { return .absent }
        guard asking.pendingId.flatMap(nonBlank) != nil else { return .unbindable(asking) }
        return bound == nil ? .asking(asking) : .replaced
    }

    private static func nonBlank(_ value: String) -> String? {
        value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : value
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
    /// The iPhone is out of range: the message could not have travelled.
    case linkDown
    /// The iPhone is here, but it has lost the Mac. A different sentence,
    /// because a different thing is broken and the wrist can see which.
    case macLinkDown
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
        // Held on the phone (ADR-0032) is not "taken" either: the Mac has not
        // seen it, and the card is where it says so — same two beats.
        case .failed, .unknown, .refused, .queued: return beats(for: .error)
        }
    }
}
