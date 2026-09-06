import Foundation

/// The two notification categories that carry actions, shared by the iPhone,
/// the Mac, and the APNs payload so a closed-app push shows the same buttons.
public enum NotificationCategoryID: String, Sendable, CaseIterable {
    case approval
    case question

    /// The UNNotificationCategory id for this cue, if it has actions.
    public static func forSound(_ sound: NotificationSound) -> NotificationCategoryID? {
        switch sound {
        case .needsApproval: return .approval
        case .needsAnswer: return .question
        default: return nil
        }
    }
}

/// Banner buttons, shared by both apps' `UNNotificationAction` identifiers.
public enum NotificationActionID: String, Sendable, CaseIterable {
    case approve
    case deny
    case answer
}

/// Keys both channels put in notification `userInfo` / the APNs payload so a
/// banner action can find the session and the pending approval.
public enum NotificationUserInfoKey {
    public static let sessionId = "sessionId"
    public static let approvalId = "approvalId"

    public static func make(sessionId: String?, approvalId: String? = nil) -> [String: String] {
        var info: [String: String] = [:]
        if let sessionId, !sessionId.isEmpty { info[Self.sessionId] = sessionId }
        if let approvalId, !approvalId.isEmpty { info[Self.approvalId] = approvalId }
        return info
    }
}

/// What `/decision` or `/answer` said about a wait the banner tried to resolve.
public enum WaitActionResult: Sendable, Equatable {
    case accepted
    /// 404 or 409: the wait is already gone — open the session instead.
    case alreadyResolved
    case failed

    public init(statusCode: Int?) {
        guard let statusCode else { self = .failed; return }
        if (200..<300).contains(statusCode) { self = .accepted }
        else if statusCode == 404 || statusCode == 409 { self = .alreadyResolved }
        else { self = .failed }
    }

    public var shouldOpenSession: Bool { self == .alreadyResolved }
}
