@preconcurrency import ActivityKit
import Foundation

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
    func sync(needsResponse: Int, working: Int, done: Int,
              topProject: String?, topSessionId: String?) async {
        let total = needsResponse + working + done
        guard total > 0 else { await end(); return }

        let state = VibeBuddyActivityAttributes.ContentState(
            needsResponse: needsResponse, working: working, done: done,
            topProject: topProject, topSessionId: topSessionId)
        let content = ActivityContent(state: state, staleDate: nil)

        if let activity {
            await activity.update(content)   // local update (foreground); push covers background
        } else {
            guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
            // Request a push token so the Mac can update the activity in the background.
            // Falls back to local-only updates if the request fails.
            guard let started = try? Activity.request(
                attributes: VibeBuddyActivityAttributes(), content: content, pushType: .token)
            else { return }
            activity = started
            observePushToken(started)
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
