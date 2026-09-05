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
    /// Several devices were excluded, each for a different one of the reasons
    /// above; no single reason would be true of all of them.
    case mixed
    /// This Mac has no APNs key, so it cannot push at all.
    case apnsNotConfigured
    /// Nothing has uploaded a push token. The registry lives in memory, so this
    /// is what a Mac that has restarted looks like until the phone opens again.
    case noRegisteredDevice
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
    /// it, so a reason is recorded only when nobody did; with one paired phone,
    /// which is the shape this runs in, that is simply the reason.
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
        var exclusions = Set<CueSkipReason>()
        for device in registered {
            guard (device.categories ?? .default).isEnabled(alert.sound) else {
                exclusions.insert(.category)
                continue
            }
            var level = alert.delivery
            if device.quietMode == true {
                level = min(level, DeliveryMatrix.level(for: alert.sound, attention: .muted))
            }
            guard level.interrupts else {
                exclusions.insert(.quiet)
                continue
            }
            recipients.append(PushRecipient(device: device, level: level))
        }
        guard recipients.isEmpty else { return PushFanout(recipients: recipients, skip: nil) }
        // One reason only when it is true of every excluded device; the registry
        // is a dictionary's values, so "first" would otherwise be arbitrary.
        return PushFanout(recipients: [], skip: exclusions.count == 1 ? exclusions.first : .mixed)
    }
}
