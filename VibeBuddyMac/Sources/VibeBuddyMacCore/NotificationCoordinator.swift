import Foundation
import VibeBuddyKit

/// Sink for "play this cue for this session" events. The macOS app's concrete
/// implementation posts a local notification with the cue's sound; tests use a spy.
public protocol AttentionNotifier {
    func notify(_ alert: SoundAlert)
}

/// Feeds each snapshot through the shared `SoundPolicy` and forwards the cues it
/// earns to `notifier`. All the *when to ring* logic lives in `SoundPolicy`
/// (unit-tested in VibeBuddyKit); this type only supplies the ambient context
/// (clock, app-active, Quiet mode) and fans the decisions out.
public final class NotificationCoordinator {
    private let notifier: AttentionNotifier
    private let policy: SoundPolicy

    public init(notifier: AttentionNotifier, policy: SoundPolicy = SoundPolicy()) {
        self.notifier = notifier
        self.policy = policy
    }

    public func observe(_ sessions: [AgentSession], now: Date = Date(),
                        appActive: Bool, quietMode: Bool,
                        focusedSessionIDs: Set<String> = []) {
        let input = SoundPolicyInput(sessions: sessions, now: now,
                                     appActive: appActive, quietMode: quietMode,
                                     focusedSessionIDs: focusedSessionIDs)
        for alert in policy.evaluate(input) {
            notifier.notify(alert)
        }
    }
}
