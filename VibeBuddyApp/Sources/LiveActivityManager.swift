@preconcurrency import ActivityKit
import Foundation

/// Starts / updates / ends the Live Activity from the app, mirroring the
/// dashboard counts onto the lock screen and Dynamic Island. All ActivityKit
/// calls stay inside this @MainActor type so the `Activity` never crosses an
/// isolation boundary.
@MainActor
final class LiveActivityManager {
    private var activity: Activity<VibeBuddyActivityAttributes>?

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
            await activity.update(content)
        } else {
            guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
            activity = try? Activity.request(
                attributes: VibeBuddyActivityAttributes(), content: content)
        }
    }

    func end() async {
        guard let activity else { return }
        await activity.end(nil, dismissalPolicy: .immediate)
        self.activity = nil
    }
}
