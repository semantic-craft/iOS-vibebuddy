import Foundation
import VibeBuddyKit

/// Sink for "play this cue for this session" events. The macOS app's concrete
/// implementation posts a local notification with the cue's sound; tests use a spy.
public protocol AttentionNotifier {
    func notify(_ alert: SoundAlert) async -> LocalNotificationAttempt
    /// Take back notifications whose session is no longer waiting: a banner or
    /// a list entry for an answered approval describes something nobody is
    /// blocked on any more. Identifiers are `SoundAlert.notificationID`.
    func withdraw(_ identifiers: [String]) async
}

/// Feeds each snapshot through the shared `SoundPolicy` and forwards the cues it
/// earns to `notifier`. All the *when to ring* and *how loud* logic lives in
/// `SoundPolicy` (unit-tested in VibeBuddyKit); this type only supplies the
/// ambient context (clock, app-active, Quiet mode, focused terminals), fans the
/// decisions out, records delivery, and hands the same cues back so the push to
/// the phone is built from one decision rather than a second policy.
public final class NotificationCoordinator: @unchecked Sendable {
    private let notifier: AttentionNotifier
    private let policy: SoundPolicy
    private let delivery: (any NotificationDeliveryRecording)?
    /// What was posted for each waiting session, so it can be withdrawn the
    /// moment the session stops waiting. Completions are never tracked.
    private var ledger = WaitingNotificationLedger()

    public init(
        notifier: AttentionNotifier,
        policy: SoundPolicy = SoundPolicy(),
        delivery: (any NotificationDeliveryRecording)? = nil
    ) {
        self.notifier = notifier
        self.policy = policy
        self.delivery = delivery
    }

    @discardableResult
    public func observe(_ sessions: [AgentSession], now: Date = Date(),
                        appActive: Bool, quietMode: Bool,
                        focusedSessionIDs: Set<String> = []) async -> [SoundAlert] {
        let input = SoundPolicyInput(sessions: sessions, now: now,
                                     appActive: appActive, quietMode: quietMode,
                                     focusedSessionIDs: focusedSessionIDs)
        let alerts = policy.evaluate(input)
        // Withdraw before posting: a session that left one wait and entered
        // another in the same snapshot keeps only the new cue.
        let stale = ledger.withdrawals(for: sessions)
        if !stale.isEmpty { await notifier.withdraw(stale) }
        ledger.record(alerts)
        for alert in alerts {
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
        return alerts
    }
}
