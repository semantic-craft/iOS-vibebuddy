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
    private var pendingSessions: (sessions: [AgentSession], allowsActions: Bool)?
    private var reconciliation: Task<Void, Never>?
    /// Reports the activity's APNs push token (hex) whenever it's produced or rotates,
    /// so the Mac can push content-state updates while the app is backgrounded
    /// (dynamic-island/02). Local updates via `update(_:)` still happen regardless.
    var onPushToken: (@MainActor (String) -> Void)?

    /// Reflect the latest counts. Starts the activity on first non-empty state,
    /// updates it thereafter, and ends it when everything is gone.
    func sync(sessions: [AgentSession], allowsActions: Bool = true) async {
        // ActivityKit operations suspend. Serialize them so a reconnect/stop
        // cannot create an activity while an earlier reconciliation ends it.
        pendingSessions = (sessions, allowsActions)
        if let reconciliation {
            await reconciliation.value
            return
        }
        let task = Task { @MainActor in
            while let sessions = self.pendingSessions {
                self.pendingSessions = nil
                await self.reconcile(sessions: sessions.sessions, allowsActions: sessions.allowsActions)
            }
            self.reconciliation = nil
        }
        reconciliation = task
        await task.value
    }

    private func reconcile(sessions allSessions: [AgentSession], allowsActions: Bool) async {
        // The island counts what is current (`SessionCurrency`), like every
        // other summary line; the approval target below still looks at every
        // session, since a wait is current by definition.
        let sessions = SessionCurrency.current(allSessions, now: Date())
        let summary = TaskPresentationSummary(sessions: sessions)
        let existing = Activity<VibeBuddyActivityAttributes>.activities
        let reusable = existing.filter { $0.activityState == .active || $0.activityState == .stale }
        let retained = summary.isEmpty ? nil : (
            reusable.first { $0.id == activity?.id } ?? reusable.sorted { $0.id < $1.id }.first)
        if activity?.id != retained?.id {
            tokenObserver?.cancel()
            tokenObserver = nil
            activity = retained
            if let retained { observePushToken(retained) }
        }
        // Activities survive process death. Reclaim one and dismiss old copies,
        // including when the first snapshot after relaunch is empty.
        for old in existing where old.id != retained?.id {
            await old.end(nil, dismissalPolicy: .immediate)
        }
        guard !summary.isEmpty else { return }
        let leading = sessions.leadingPresentationSession

        // The island can answer the first pending approval (island-approve/01) —
        // not necessarily the leading session, since an error outranks it.
        let target = allowsActions ? ActivityApprovalTarget.select(from: sessions) : nil
        let previous = activity?.content.state
        let state = VibeBuddyActivityAttributes.ContentState(
            summary: summary,
            topProject: leading?.project,
            topSessionId: leading?.id,
            approvalId: target?.approvalID,
            approvalTitle: target?.title,
            approvalDetail: target?.detail,
            // A decision already sent from the island stays shown while the Mac
            // still reports the same request; a new request starts clean.
            decisionSent: target != nil && previous?.approvalId == target?.approvalID ? previous?.decisionSent : nil)
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
        if let tokenData = activity.pushToken {
            onPushToken?(tokenData.map { String(format: "%02x", $0) }.joined())
        }
        tokenObserver = Task { [weak self] in
            for await tokenData in activity.pushTokenUpdates {
                guard !Task.isCancelled, let self,
                      self.activity?.id == activity.id else { return }
                let hex = tokenData.map { String(format: "%02x", $0) }.joined()
                self.onPushToken?(hex)
            }
        }
    }

    func end() async {
        await sync(sessions: [])
    }
}
