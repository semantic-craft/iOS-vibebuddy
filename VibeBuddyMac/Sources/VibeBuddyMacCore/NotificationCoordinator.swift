import Foundation
import VibeBuddyKit

/// Sink for "this session just needs you" events. The macOS app's concrete
/// implementation posts a local notification; tests use a spy.
public protocol AttentionNotifier {
    func notify(_ session: AgentSession)
}

/// Watches the snapshot stream and fires `notifier` exactly once per *fresh*
/// transition into needsResponse — never the backlog already waiting on the
/// first snapshot, and never twice for a session that keeps waiting. Mirrors
/// the iOS dashboard's notification behaviour, reusing the tested `AttentionDiff`.
public final class NotificationCoordinator {
    private let notifier: AttentionNotifier
    private var lastSessions: [AgentSession] = []
    private var seenFirstSnapshot = false

    public init(notifier: AttentionNotifier) {
        self.notifier = notifier
    }

    public func observe(_ sessions: [AgentSession]) {
        if seenFirstSnapshot {
            for session in AttentionDiff.newlyNeedingResponse(old: lastSessions, new: sessions) {
                notifier.notify(session)
            }
        }
        lastSessions = sessions
        seenFirstSnapshot = true
    }
}
