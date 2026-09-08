import Foundation
import VibeBuddyKit

/// Receipt from the Mac, never a claim that the agent finished executing.
enum PhoneActionResult: Equatable, Sendable {
    case sending, received, expired, failed, unconfirmed, notPaired

    var message: String {
        switch self {
        case .sending: "Sending to Mac…"
        case .received: "Mac received the request. Agent execution is not yet confirmed."
        case .expired: "This request expired or can no longer be handled. Check the current task."
        case .failed: "Sending failed. Your answer is kept; check the connection before retrying."
        case .unconfirmed: "The result could not be confirmed. Check the task on Mac before sending again."
        case .notPaired: "No paired Mac connection. Your answer has not been sent."
        }
    }

    init(statusCode: Int?) {
        switch statusCode {
        case 200: self = .received
        case 202, 404, 409, 410: self = .expired
        case 400, 401, 403, 422: self = .failed
        default: self = .unconfirmed
        }
    }
}

/// What the Mac said about a **stop**. Its `/answer` reply carries a `status`
/// field, and that field — not the HTTP code — is the authority: `refused` and
/// `failed` are both 409, and they mean opposite things to the person who
/// tapped. `refused` says this stop no longer applies, so look at the task
/// rather than tapping again; `failed` says nothing was carried out, so a
/// second tap is the sensible thing.
enum StopDelivery: Equatable, Sendable {
    /// Handed to Codex. Not stopped — only the next snapshot can say that.
    case accepted
    /// No longer applicable: not this agent, not running any more, or aimed at
    /// a turn that has already ended.
    case refused
    /// It did not happen. Nothing was interrupted.
    case failed
    /// The request may have arrived, but its receipt could not be confirmed.
    case unconfirmed

    /// The Mac's own words for the outcome, read from the response body.
    /// A lost or unreadable receipt is not proof that nothing happened.
    init(status: String?) {
        switch status {
        case "accepted": self = .accepted
        case "refused": self = .refused
        case "failed": self = .failed
        default: self = .unconfirmed
        }
    }
}
