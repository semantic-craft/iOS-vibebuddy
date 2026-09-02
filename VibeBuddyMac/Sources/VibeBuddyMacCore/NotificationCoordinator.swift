import Foundation
import VibeBuddyKit

/// Sink for "play this cue for this session" events. The macOS app's concrete
/// implementation posts a local notification with the cue's sound; tests use a spy.
public protocol AttentionNotifier {
    func notify(_ alert: SoundAlert) async -> LocalNotificationAttempt
}

/// Feeds each snapshot through the shared `SoundPolicy` and forwards the cues it
/// earns to `notifier`. All the *when to ring* logic lives in `SoundPolicy`
/// (unit-tested in VibeBuddyKit); this type only supplies the ambient context
/// (clock, app-active, Quiet mode), fans the decisions out, and records delivery
/// *after* those existing rules.
public final class NotificationCoordinator: @unchecked Sendable {
    private let notifier: AttentionNotifier
    private let policy: SoundPolicy
    private let delivery: (any NotificationDeliveryRecording)?

    public init(
        notifier: AttentionNotifier,
        policy: SoundPolicy = SoundPolicy(),
        delivery: (any NotificationDeliveryRecording)? = nil
    ) {
        self.notifier = notifier
        self.policy = policy
        self.delivery = delivery
    }

    public func observe(_ sessions: [AgentSession], now: Date = Date(),
                        appActive: Bool, quietMode: Bool,
                        focusedSessionIDs: Set<String> = []) async {
        let input = SoundPolicyInput(sessions: sessions, now: now,
                                     appActive: appActive, quietMode: quietMode,
                                     focusedSessionIDs: focusedSessionIDs)
        for alert in policy.evaluate(input) {
            let attempt = await notifier.notify(alert)
            guard attempt.shouldRecord else { continue }
            await delivery?.record(NotificationDeliveryRecord(
                channel: .local,
                outcome: attempt.outcome,
                sessionID: alert.sessionID,
                sound: alert.sound.rawValue,
                failureReason: attempt.failureReason,
                timestamp: now
            ))
        }
    }
}
