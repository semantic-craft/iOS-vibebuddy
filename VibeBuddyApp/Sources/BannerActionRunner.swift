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
        hold: ((QueuedSessionAction, ConnectionFailureReason?) -> Void)? = nil,
        phoneHasTailnet: () -> Bool = { PhoneNetwork.hasTailnetAddress() }
    ) async -> BannerActionOutcome {
        guard let action = NotificationActionID(rawValue: actionIdentifier) else { return .ignored }
        let sessionId = userInfo[NotificationUserInfoKey.sessionId] as? String
        let approvalId = userInfo[NotificationUserInfoKey.approvalId] as? String
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
            // A banner reply names no question id; the Mac answers whichever
            // one the session is asking, as before. Held, it is aimed at the
            // question the live snapshot shows when it is delivered — the
            // phone's own answer path re-reads the Mac before sending.
            holdable = nil
            result = await client.answerResult(pairing, sessionId: sessionId, answer: reply)
        }
        switch result {
        case .accepted:
            return .ignored
        case .alreadyResolved, .failed:
            // The Mac answered: gone, or refused. Nothing to hold.
            return .openSession(sessionId)
        case .unreachable:
            // Nothing reached the Mac. Hold what can be held; the rest brings
            // the person to the session, where the connection state explains.
            guard let hold, let holdable else { return .openSession(sessionId) }
            let reason = ConnectionDiagnosis.diagnose(endpoint: pairing.endpoint, kind: .unreachable,
                                                      phoneHasTailnet: phoneHasTailnet())
            hold(QueuedSessionAction(id: key, sessionId: sessionId, action: holdable, origin: .banner,
                                     pairingEpoch: epoch, queuedAt: now), reason)
            return .held(sessionId: sessionId, key: key)
        }
    }
}
