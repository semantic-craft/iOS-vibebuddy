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

    /// Say "finished, still unread" again for a followed session. The same
    /// `agentDone` cue as the completion itself, so the notifier replaces the
    /// earlier banner rather than stacking a new one. Nothing is posted when the
    /// Mac has the completion category off or Focus mode is on (a completion
    /// never survives Quiet mode). Returns whether a post was attempted.
    @discardableResult
    public func remind(_ session: AgentSession, now: Date = Date(), quietMode: Bool,
                       categories: NotificationCategoryPrefs = .default) async -> Bool {
        let alert = SoundAlert(session: session, sound: .agentDone)
        guard categories.isEnabled(alert.sound),
              !quietMode || alert.sound.survivesQuietMode else { return false }
        let attempt = await notifier.notify(alert)
        if attempt.shouldRecord {
            await delivery?.record(NotificationDeliveryRecord(
                channel: .local, outcome: attempt.outcome, sessionID: alert.sessionID,
                sound: alert.sound.rawValue, failureReason: attempt.failureReason, timestamp: now))
        }
        return true
    }

    /// `categories` is this Mac's own switch set: a cue the policy earned but
    /// the user turned off is dropped here and never posted. Quiet mode is
    /// already applied inside the policy, so Focus narrows what is left to
    /// approvals exactly as before.
    public func observe(_ sessions: [AgentSession], now: Date = Date(),
                        appActive: Bool, quietMode: Bool,
                        focusedSessionIDs: Set<String> = [],
                        categories: NotificationCategoryPrefs = .default) async {
        let input = SoundPolicyInput(sessions: sessions, now: now,
                                     appActive: appActive, quietMode: quietMode,
                                     focusedSessionIDs: focusedSessionIDs)
        for alert in categories.filter(policy.evaluate(input)) {
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
