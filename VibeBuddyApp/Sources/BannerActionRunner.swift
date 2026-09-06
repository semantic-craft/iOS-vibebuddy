import Foundation
import VibeBuddyKit

/// What a banner action should do after the Mac has been asked (or skipped).
enum BannerActionOutcome: Equatable {
    case ignored
    case openSession(String)
}

/// Maps the three shared action ids onto `DecisionClient`. Default tap stays
/// in `AppDelegate` — this only handles Approve / Deny / Reply.
enum BannerActionRunner {
    static func perform(
        actionIdentifier: String,
        userInfo: [AnyHashable: Any],
        text: String?,
        pairing: PairingPayload?,
        client: DecisionClient
    ) async -> BannerActionOutcome {
        guard let action = NotificationActionID(rawValue: actionIdentifier) else { return .ignored }
        let sessionId = userInfo[NotificationUserInfoKey.sessionId] as? String
        let approvalId = userInfo[NotificationUserInfoKey.approvalId] as? String
        guard let sessionId, !sessionId.isEmpty else { return .ignored }
        guard let pairing else { return .openSession(sessionId) }

        let result: WaitActionResult
        switch action {
        case .approve:
            guard let approvalId, !approvalId.isEmpty else { return .openSession(sessionId) }
            result = await client.decideResult(pairing, approvalId: approvalId, decision: .allow)
        case .deny:
            guard let approvalId, !approvalId.isEmpty else { return .openSession(sessionId) }
            result = await client.decideResult(pairing, approvalId: approvalId, decision: .deny)
        case .answer:
            let reply = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !reply.isEmpty else { return .openSession(sessionId) }
            result = await client.answerResult(pairing, sessionId: sessionId, answer: reply)
        }
        // A failed background request must bring the user to the session,
        // where the existing connection state makes a retry possible.
        return result == .accepted ? .ignored : .openSession(sessionId)
    }
}
