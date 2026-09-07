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
