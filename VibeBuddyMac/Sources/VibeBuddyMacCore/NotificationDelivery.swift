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
    /// A phone's push registration was stood down because Apple kept refusing
    /// its token (`Unregistered`, or `BadDeviceToken` for a day with nothing
    /// accepted in between). One row per stand-down, in place of a `failed`
    /// per push to a phone that is gone; `apnsReason` carries Apple's word and
    /// `deviceID` names the phone. Housekeeping, not a send: it never latches
    /// a health diagnostic and never clears one.
    case pruned
}

public enum NotificationDeliveryChannel: String, Codable, Sendable, Equatable {
    case local
    case apns
    /// The phone's own local notification, as the phone reported it
    /// (`POST /notified`): `scheduled` when it posted the cue itself,
    /// `skipped` (`pushCovered`) when it left the cue to a push that had
    /// already landed. Reported, not observed — it never moves this Mac's health.
    case phone
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

    /// What one send result means for *keeping* the token, which is a different
    /// question from whether the send worked.
    /// `reason` is the `reason` field of APNs' error body. A 400 is only about
    /// the token when Apple says `BadDeviceToken`; the same status also answers
    /// `BadTopic`, `BadCollapseId`, `PayloadEmpty` and other request faults that
    /// say nothing about the device, so those never evict.
    public static func tokenOutcome(status: Int?, reason: String? = nil, everAccepted: Bool) -> APNsTokenOutcome {
        guard let status else { return .keep }                       // offline: says nothing
        if (200..<300).contains(status) { return .accepted }
        if status == 410 { return .unregistered }
        if status == 400 {
            guard reason == "BadDeviceToken" else { return .keep }   // a request fault, not the phone
            return everAccepted ? .suspect : .neverValid
        }
        return .keep                                                 // throttled, 5xx, auth
    }
}

/// Whether a device stays in the registry after a send.
///
/// The split at 400 is the whole point. `BadDeviceToken` means either "this
/// token is junk" or "this Mac is pointed at the wrong APNs environment", and
/// those need opposite handling: dropping junk is right, while dropping every
/// device because the Mac is misconfigured would empty the registry and recreate
/// the silent failure the registry exists to prevent. Apple having accepted the
/// token at least once is what tells the two apart.
public enum APNsTokenOutcome: String, Sendable, Equatable {
    /// Apple took it — the token is real, and stays real.
    case accepted
    /// 410 Unregistered: the app was deleted or the device is gone.
    case unregistered
    /// 400 on a token Apple has never once accepted: a typo, a test fixture, or
    /// a token minted for the other APNs environment. Junk — drop it. If it was
    /// in fact a live phone, it re-registers on its next connection.
    case neverValid
    /// 400 `BadDeviceToken` on a token Apple *used to* accept. One of these
    /// points at this Mac (wrong APNs environment) as much as at the phone, so
    /// it never evicts by itself; a run of them with nothing accepted in
    /// between is what `DeviceRegistry` counts toward standing the token down.
    case suspect
    /// Everything else — offline, throttled, 5xx. Says nothing about the token.
    case keep
}

public struct NotificationDeliveryRecord: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let channel: NotificationDeliveryChannel
    public let outcome: NotificationDeliveryOutcome
    public let sessionID: String?
    public let sound: String?
    public let failureReason: String?
    public let timestamp: Date
    /// Apple's own `reason` from an APNs error body (`BadDeviceToken`,
    /// `Unregistered`, `BadTopic`, …). `failureReason` only says `apnsHTTP400`;
    /// this says which 400. Optional so rows written before it existed decode.
    public let apnsReason: String?
    /// The phone a `pruned` row is about, by its stable identity.
    public let deviceID: String?

    public init(
        id: UUID = UUID(),
        channel: NotificationDeliveryChannel,
        outcome: NotificationDeliveryOutcome,
        sessionID: String?,
        sound: String?,
        failureReason: String?,
        timestamp: Date,
        apnsReason: String? = nil,
        deviceID: String? = nil
    ) {
        self.id = id
        self.channel = channel
        self.outcome = outcome
        self.sessionID = sessionID
        self.sound = sound
        self.failureReason = failureReason
        self.timestamp = timestamp
        self.apnsReason = apnsReason
        self.deviceID = deviceID
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
    /// APNs' own `reason` string from the error body (`BadDeviceToken`,
    /// `BadTopic`, `Unregistered`, …); nil on success or when unreachable.
    public let reason: String?

    public init(outcome: NotificationDeliveryOutcome, status: Int?, failureReason: String?,
                reason: String? = nil) {
        self.outcome = outcome
        self.status = status
        self.failureReason = failureReason
        self.reason = reason
    }
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
        // What the phone did says nothing about this Mac's banners or its APNs key.
        guard record.channel != .phone else { return false }
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
        case .attempted, .skipped, .pruned:
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
