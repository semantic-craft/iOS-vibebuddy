@preconcurrency import ActivityKit
import Foundation
import VibeBuddyKit

/// Starts / updates / ends the Live Activity from the app, mirroring the
/// dashboard counts onto the lock screen and Dynamic Island. All ActivityKit
/// calls stay inside this @MainActor type so the `Activity` never crosses an
/// isolation boundary.
@MainActor
final class LiveActivityManager {
    private var activity: Activity<VibeBuddyActivityAttributes>?
    private var tokenObserver: Task<Void, Never>?
    /// Reports the activity's APNs push token (hex) whenever it's produced or rotates,
    /// so the Mac can push content-state updates while the app is backgrounded
    /// (dynamic-island/02). Local updates via `update(_:)` still happen regardless.
    var onPushToken: (@MainActor (String) -> Void)?

    /// Reflect the latest counts. Starts the activity on first non-empty state,
    /// updates it thereafter, and ends it when everything is gone.
    func sync(sessions: [AgentSession]) async {
        let summary = TaskPresentationSummary(sessions: sessions)
        guard !summary.isEmpty else { await end(); return }
        let leading = sessions.leadingPresentationSession

        let state = VibeBuddyActivityAttributes.ContentState(
            summary: summary,
            topProject: leading?.project,
            topSessionId: leading?.id)
        let content = ActivityContent(state: state, staleDate: nil)

        if let activity {
            await activity.update(content)   // local update (foreground); push covers background
        } else {
            guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
            // Demo/visual QA must not trigger a notification permission prompt.
            // Its Live Activity is local-only; paired sessions ask for a push
            // token so the Mac can update the banner while the app is in the
            // background. When the push request is refused (no aps-environment
            // entitlement: Simulator and unsigned builds), fall back to a
            // local-only activity rather than leaving the lock screen empty.
            let isDemo = ProcessInfo.processInfo.environment["VIBEBUDDY_DEMO"] == "1"
            let attributes = VibeBuddyActivityAttributes()
            if !isDemo,
               let started = try? Activity.request(attributes: attributes, content: content, pushType: .token) {
                activity = started
                observePushToken(started)
            } else if let started = try? Activity.request(attributes: attributes, content: content) {
                activity = started
            }
        }
    }

    private func observePushToken(_ activity: Activity<VibeBuddyActivityAttributes>) {
        tokenObserver?.cancel()
        tokenObserver = Task { [weak self] in
            for await tokenData in activity.pushTokenUpdates {
                let hex = tokenData.map { String(format: "%02x", $0) }.joined()
                self?.onPushToken?(hex)
            }
        }
    }

    func end() async {
        tokenObserver?.cancel(); tokenObserver = nil
        guard let activity else { return }
        await activity.end(nil, dismissalPolicy: .immediate)
        self.activity = nil
    }
}
