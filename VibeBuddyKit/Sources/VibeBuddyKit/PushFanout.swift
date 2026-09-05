import Foundation

/// Why a cue the policy earned was not said on a given channel.
///
/// One vocabulary for both channels, so the delivery log has a single result
/// code (`NotificationDeliveryOutcome.skipped`) and one set of reasons rather
/// than two. A cue that is filtered — locally or on its way to a phone — used to
/// leave nothing behind, so "the phone did not want it", "no phone was
/// listening", "the Mac decided it was not worth interrupting for" and "no cue
/// was earned" were one indistinguishable silence.
public enum CueSkipReason: String, Sendable, Equatable, Codable {
    /// The category switch for this cue is off, on this Mac or on that phone.
    case category
    /// The session's attention level reduced the cue below anything worth
    /// interrupting for — a muted session, or Quiet mode reading every session
    /// as muted.
    case attention
    /// That phone's own Quiet mode reduced it below a level worth pushing.
    case quiet
    /// The session's own terminal is frontmost, so the cue was capped to the
    /// list and never left the Mac.
    case focusedTerminal
    /// This Mac has no APNs key, so it cannot push at all.
    case apnsNotConfigured
    /// Nothing has uploaded a push token. The registry lives in memory, so this
    /// is what a Mac that has restarted looks like until the phone opens again.
    case noRegisteredDevice
    /// Several devices each refused, for different reasons. Naming one of them
    /// would claim they all agreed — and the registry is a dictionary, so which
    /// one you got would not even be stable between runs.
    case mixed
}

/// One phone this cue is going to, and how loud it will be there.
public struct PushRecipient: Equatable, Sendable {
    public let device: DeviceRegistrationPayload
    /// The delivery level after this device's own Quiet mode — never louder than
    /// the Mac already decided.
    public let level: DeliveryLevel

    public init(device: DeviceRegistrationPayload, level: DeliveryLevel) {
        self.device = device
        self.level = level
    }
}

/// Which phones one cue is sent to, and — when that is none of them — the one
/// reason to record in its place.
///
/// Pure, so the reason written to the delivery log is decided by the same rule
/// that decides the send, and both can be tested without APNs.
public struct PushFanout: Equatable, Sendable {
    public let recipients: [PushRecipient]
    public let skip: CueSkipReason?

    public init(recipients: [PushRecipient], skip: CueSkipReason?) {
        self.recipients = recipients
        self.skip = skip
    }

    /// `devices` is the whole registry. Each device's category switches decide
    /// *whether* it hears the cue at all, and its Quiet mode decides *how loud*
    /// through the same `DeliveryMatrix` the Mac used — never louder than the Mac
    /// decided. When devices disagree the cue still goes to the ones that want
    /// it, so a reason is recorded only when nobody did — and then only when they
    /// all refused for the *same* reason; otherwise `mixed`.
    /// `focusedSessionIDs` only separates two reasons for the same silence: a cue
    /// capped to the list because you are in that session's terminal, from one
    /// the session's attention level reduced. Both stay on the Mac either way.
    public static func plan(_ alert: SoundAlert,
                            devices: [DeviceRegistrationPayload],
                            apnsConfigured: Bool,
                            focusedSessionIDs: Set<String> = []) -> PushFanout {
        guard apnsConfigured else { return PushFanout(recipients: [], skip: .apnsNotConfigured) }
        // A list-only cue stays on the Mac by design — but say so, rather than
        // leaving the phone's silence to be guessed at.
        guard alert.delivery.interrupts else {
            return PushFanout(recipients: [], skip: focusedSessionIDs.contains(alert.sessionID)
                ? .focusedTerminal : .attention)
        }
        let registered = devices.filter { $0.token?.isEmpty == false }
        guard !registered.isEmpty else { return PushFanout(recipients: [], skip: .noRegisteredDevice) }

        var recipients: [PushRecipient] = []
        var refusals: Set<CueSkipReason> = []
        for device in registered {
            guard (device.categories ?? .default).isEnabled(alert.sound) else {
                refusals.insert(.category)
                continue
            }
            var level = alert.delivery
            if device.quietMode == true {
                level = min(level, DeliveryMatrix.level(for: alert.sound, attention: .muted))
            }
            guard level.interrupts else {
                refusals.insert(.quiet)
                continue
            }
            recipients.append(PushRecipient(device: device, level: level))
        }
        guard recipients.isEmpty else { return PushFanout(recipients: recipients, skip: nil) }
        return PushFanout(recipients: [], skip: refusals.count == 1 ? refusals.first : .mixed)
    }
}

/// Who hears a budget / usage notice. Independent of `DeliveryMatrix`: only the
/// `quota` category switch applies, and Quiet mode does not drop it. Missing
/// phone prefs are the phone default (quota off).
public struct QuotaPushPlan: Equatable, Sendable {
    public let recipients: [DeviceRegistrationPayload]
    public let skip: CueSkipReason?

    public init(recipients: [DeviceRegistrationPayload], skip: CueSkipReason?) {
        self.recipients = recipients
        self.skip = skip
    }
}

public enum QuotaNoticeFanout {
    /// `nil` means this Mac's quota switch is on; otherwise the skip to log.
    public static func localSkip(categories: NotificationCategoryPrefs) -> CueSkipReason? {
        categories.isEnabled(.quota) ? nil : .category
    }

    public static func plan(devices: [DeviceRegistrationPayload],
                            apnsConfigured: Bool) -> QuotaPushPlan {
        guard apnsConfigured else {
            return QuotaPushPlan(recipients: [], skip: .apnsNotConfigured)
        }
        let registered = devices.filter { $0.token?.isEmpty == false }
        guard !registered.isEmpty else {
            return QuotaPushPlan(recipients: [], skip: .noRegisteredDevice)
        }
        let wanted = registered.filter { ($0.categories ?? .default).isEnabled(.quota) }
        if wanted.isEmpty {
            return QuotaPushPlan(recipients: [], skip: .category)
        }
        return QuotaPushPlan(recipients: wanted, skip: nil)
    }
}
