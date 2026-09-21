import Foundation
import VibeBuddyKit

/// What a banner action should do after the Mac has been asked (or skipped).
enum BannerActionOutcome: Equatable {
    case ignored
    case openSession(String)
    /// The Mac could not be reached; the decision is held on this phone under
    /// the given key and will be delivered when it can be (ADR-0032). The
    /// person is told through a notification — the banner they tapped was on
    /// the wrist or the lock screen, and opening the app there is not an
    /// answer.
    case held(sessionId: String, key: String)
    /// The Mac could not be reached and the decision could not be held
    /// either (queue full, or the same target is being delivered right now).
    /// Nothing was applied; the person is told to decide again.
    case notHeld(QueuedSessionAction)
    /// The POST went out and the receipt was lost: the Mac may have acted.
    /// Never held or retried; the person is told to look before tapping again.
    case unconfirmed(QueuedSessionAction)
}

/// Maps the three shared action ids onto `DecisionClient`. Default tap stays
/// in `AppDelegate` — this only handles Approve / Deny / Reply.
///
/// Every request goes out under a fresh idempotency key, and the same key is
/// what the hold is filed under, so the retry the phone makes later is the
/// same request to the Mac, not a second one.
enum BannerActionRunner {
    static func perform(
        actionIdentifier: String,
        userInfo: [AnyHashable: Any],
        text: String?,
        pairing: PairingPayload?,
        client: DecisionClient,
        epoch: String = "",
        now: Date = Date(),
        hold: ((QueuedSessionAction, ConnectionFailureReason?) async -> Bool)? = nil,
        phoneHasTailnet: () -> Bool = { PhoneNetwork.hasTailnetAddress() }
    ) async -> BannerActionOutcome {
        guard let action = NotificationActionID(rawValue: actionIdentifier) else { return .ignored }
        let sessionId = userInfo[NotificationUserInfoKey.sessionId] as? String
        let approvalId = userInfo[NotificationUserInfoKey.approvalId] as? String
        let questionId = userInfo[NotificationUserInfoKey.questionId] as? String
        guard let sessionId, !sessionId.isEmpty else { return .ignored }
        guard let pairing else { return .openSession(sessionId) }

        let key = UUID().uuidString
        let result: WaitActionResult
        let holdable: WatchSessionAction?
        switch action {
        case .approve, .deny:
            guard let approvalId, !approvalId.isEmpty else { return .openSession(sessionId) }
            let choice: WatchApprovalChoice = action == .approve ? .allow : .deny
            holdable = .approval(id: approvalId, choice: choice)
            result = await client.decideResult(pairing, approvalId: approvalId, decision: choice.decision, requestID: key)
        case .answer:
            let reply = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !reply.isEmpty else { return .openSession(sessionId) }
            // The Mac answers whichever question the session is asking, as
            // before. A reply can be held only when the notification named
            // its question (a newer Mac's push, or this phone's own cue); an
            // older push leaves it unnamed, and an unnamed reply is not held.
            holdable = questionId.flatMap { $0.isEmpty ? nil : .answer(pendingId: $0, text: reply) }
            result = await client.answerResult(pairing, sessionId: sessionId, answer: reply)
        }
        let record = holdable.map {
            QueuedSessionAction(id: key, sessionId: sessionId, action: $0, origin: .banner,
                                pairingEpoch: epoch, queuedAt: now)
        }
        switch result {
        case .accepted:
            return .ignored
        case .alreadyResolved:
            // The Mac answered: the request is gone. Look at the session.
            return .openSession(sessionId)
        case .failed:
            // Refused by the Mac, or a timeout / reset after the body went
            // out. The Mac may have acted; say so rather than open an app
            // that a background action cannot bring forward anyway.
            guard let record else { return .openSession(sessionId) }
            return .unconfirmed(record)
        case .unreachable:
            // Nothing reached the Mac. Hold what can be held; the rest brings
            // the person to the session, where the connection state explains.
            guard let hold, let record else { return .openSession(sessionId) }
            let reason = ConnectionDiagnosis.diagnose(endpoint: pairing.endpoint, kind: .unreachable,
                                                      phoneHasTailnet: phoneHasTailnet())
            guard await hold(record, reason) else { return .notHeld(record) }
            return .held(sessionId: sessionId, key: key)
        }
    }
}
