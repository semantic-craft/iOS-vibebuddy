import Foundation

/// Why a cue the policy earned reached no phone at all.
///
/// A push that is never attempted leaves nothing behind, so a cue that only ever
/// landed on the Mac used to be indistinguishable in the delivery log from a cue
/// the phone was never owed — and from a cue that was never earned. These are the
/// reasons, recorded in place of the send.
public enum PushSkipReason: String, Sendable, Equatable, Codable {
    /// This Mac has no APNs key, so it cannot push at all.
    case apnsNotConfigured
    /// The Mac decided this cue is not worth interrupting for — a `list` or
    /// `drop` level, typically because the session is muted or you are looking
    /// at its own terminal. Deliberate, and previously invisible.
    case notLoudEnough
    /// Nothing has uploaded a push token. The registry lives in memory, so this
    /// is what a Mac that has restarted looks like until the phone opens again.
    case noRegisteredDevice
    /// Every registered device has this cue's category switched off.
    case categoryOff
    /// Every registered device's own Quiet mode reduced the cue below a level
    /// worth pushing.
    case deviceQuietMode
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
    public let skip: PushSkipReason?

    public init(recipients: [PushRecipient], skip: PushSkipReason?) {
        self.recipients = recipients
        self.skip = skip
    }

    /// `devices` is the whole registry. Each device's category switches decide
    /// *whether* it hears the cue at all, and its Quiet mode decides *how loud*
    /// through the same `DeliveryMatrix` the Mac used — never louder than the Mac
    /// decided. When devices disagree the cue still goes to the ones that want
    /// it, so a reason is recorded only when nobody did; with one paired phone,
    /// which is the shape this runs in, that is simply the reason.
    public static func plan(_ alert: SoundAlert,
                            devices: [DeviceRegistrationPayload],
                            apnsConfigured: Bool) -> PushFanout {
        guard apnsConfigured else { return PushFanout(recipients: [], skip: .apnsNotConfigured) }
        // A list-only cue stays on the Mac by design — but say so, rather than
        // leaving the phone's silence to be guessed at.
        guard alert.delivery.interrupts else { return PushFanout(recipients: [], skip: .notLoudEnough) }
        let registered = devices.filter { $0.token?.isEmpty == false }
        guard !registered.isEmpty else { return PushFanout(recipients: [], skip: .noRegisteredDevice) }

        var recipients: [PushRecipient] = []
        var firstSkip: PushSkipReason?
        for device in registered {
            guard (device.categories ?? .default).isEnabled(alert.sound) else {
                firstSkip = firstSkip ?? .categoryOff
                continue
            }
            var level = alert.delivery
            if device.quietMode == true {
                level = min(level, DeliveryMatrix.level(for: alert.sound, attention: .muted))
            }
            guard level.interrupts else {
                firstSkip = firstSkip ?? .deviceQuietMode
                continue
            }
            recipients.append(PushRecipient(device: device, level: level))
        }
        guard recipients.isEmpty else { return PushFanout(recipients: recipients, skip: nil) }
        return PushFanout(recipients: [], skip: firstSkip)
    }
}
