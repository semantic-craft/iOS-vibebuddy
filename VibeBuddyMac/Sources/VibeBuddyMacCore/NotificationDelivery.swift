import Foundation

/// Honest send outcomes. API success is never a device receipt — that would
/// claim the banner was shown, which this process cannot know.
public enum NotificationDeliveryOutcome: String, Codable, Sendable, CaseIterable, Equatable {
    case attempted
    case scheduled
    case accepted
    case failed
    /// The cue was earned but nothing was sent — no key, nobody registered, not
    /// loud enough to interrupt, or every device had it switched off.
    /// `failureReason` carries which one. Not a failure: nothing broke, so it
    /// never latches a health diagnostic and never clears a standing one.
    case skipped
}

public enum NotificationDeliveryChannel: String, Codable, Sendable, Equatable {
    case local
    case apns
}

public enum NotificationAuthorization: String, Sendable, Equatable {
    case authorized
    case denied
    case notDetermined
    case unknown
}

public struct NotificationDeliveryClassification: Equatable, Sendable {
    public let outcome: NotificationDeliveryOutcome
    public let failureReason: String?
}

/// Local banner: permission off is `failed`; a successful `add` is `scheduled`.
public enum LocalNotificationDelivery {
    public static func classify(authorized: Bool, scheduleError: Error?) -> NotificationDeliveryClassification {
        if !authorized {
            return NotificationDeliveryClassification(outcome: .failed, failureReason: "permissionDenied")
        }
        if scheduleError != nil {
            return NotificationDeliveryClassification(outcome: .failed, failureReason: "scheduleFailed")
        }
        return NotificationDeliveryClassification(outcome: .scheduled, failureReason: nil)
    }
}

/// APNs HTTP: 2xx is `accepted` by Apple's servers. Anything else is `failed`.
public enum APNsDelivery {
    public static func classify(status: Int?, error: Error?) -> NotificationDeliveryClassification {
        if error != nil {
            return NotificationDeliveryClassification(outcome: .failed, failureReason: "apnsUnreachable")
        }
        guard let status else {
            return NotificationDeliveryClassification(outcome: .failed, failureReason: "apnsUnreachable")
        }
        if (200..<300).contains(status) {
            return NotificationDeliveryClassification(outcome: .accepted, failureReason: nil)
        }
        return NotificationDeliveryClassification(outcome: .failed, failureReason: "apnsHTTP\(status)")
    }
}

public struct NotificationDeliveryRecord: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let channel: NotificationDeliveryChannel
    public let outcome: NotificationDeliveryOutcome
    public let sessionID: String?
    public let sound: String?
    public let failureReason: String?
    public let timestamp: Date

    public init(
        id: UUID = UUID(),
        channel: NotificationDeliveryChannel,
        outcome: NotificationDeliveryOutcome,
        sessionID: String?,
        sound: String?,
        failureReason: String?,
        timestamp: Date
    ) {
        self.id = id
        self.channel = channel
        self.outcome = outcome
        self.sessionID = sessionID
        self.sound = sound
        self.failureReason = failureReason
        self.timestamp = timestamp
    }
}

public struct LocalNotificationAttempt: Equatable, Sendable {
    public let outcome: NotificationDeliveryOutcome
    public let failureReason: String?
    public let shouldRecord: Bool

    public static func scheduled() -> LocalNotificationAttempt {
        LocalNotificationAttempt(outcome: .scheduled, failureReason: nil, shouldRecord: true)
    }

    public static func failed(reason: String) -> LocalNotificationAttempt {
        LocalNotificationAttempt(outcome: .failed, failureReason: reason, shouldRecord: true)
    }

    public static let skipped = LocalNotificationAttempt(
        outcome: .attempted, failureReason: nil, shouldRecord: false)
}

public struct APNsSendResult: Equatable, Sendable {
    public let outcome: NotificationDeliveryOutcome
    public let status: Int?
    public let failureReason: String?
}

public protocol NotificationDeliveryRecording: Sendable {
    func record(_ record: NotificationDeliveryRecord) async
}

public protocol APNsHTTPClient: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: APNsHTTPClient {}

/// Latches one diagnostic per failure reason. Recovery (`scheduled` / `accepted`)
/// clears health. This never posts a notification of its own.
public struct NotificationDeliveryHealthTracker: Equatable, Sendable {
    public var debounce: TimeInterval
    public private(set) var lastAttempt: NotificationDeliveryRecord?
    public private(set) var latchedFailure: NotificationDeliveryRecord?
    private var lastFailurePromptAt: Date?

    public init(debounce: TimeInterval = 5 * 60) {
        self.debounce = debounce
    }

    /// Returns true only when a new failure diagnostic should surface.
    @discardableResult
    public mutating func apply(_ record: NotificationDeliveryRecord, now: Date) -> Bool {
        lastAttempt = record
        switch record.outcome {
        case .scheduled, .accepted:
            latchedFailure = nil
            lastFailurePromptAt = nil
            return false
        case .failed:
            if let latched = latchedFailure,
               latched.failureReason == record.failureReason,
               let prompted = lastFailurePromptAt,
               now.timeIntervalSince(prompted) < debounce {
                return false
            }
            latchedFailure = record
            lastFailurePromptAt = now
            return true
        case .attempted, .skipped:
            return false
        }
    }
}

public struct NotificationDeliveryHealth: Equatable, Sendable {
    public var authorization: NotificationAuthorization
    public var apnsConfigured: Bool
    public var lastAttempt: NotificationDeliveryRecord?
    public var latchedFailure: NotificationDeliveryRecord?

    public init(
        authorization: NotificationAuthorization = .notDetermined,
        apnsConfigured: Bool = false,
        lastAttempt: NotificationDeliveryRecord? = nil,
        latchedFailure: NotificationDeliveryRecord? = nil
    ) {
        self.authorization = authorization
        self.apnsConfigured = apnsConfigured
        self.lastAttempt = lastAttempt
        self.latchedFailure = latchedFailure
    }

    public static func summary(for outcome: NotificationDeliveryOutcome) -> String {
        "Last attempt: \(outcome.rawValue)"
    }
}
