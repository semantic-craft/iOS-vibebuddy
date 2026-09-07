import ActivityKit
import XCTest
import VibeBuddyKit
@testable import VibeBuddyApp

/// Exercise the real system activity registry, not a mock which loses its state
/// alongside the manager. Run only on an isolated simulator/test installation.
@MainActor
final class LiveActivityRecoveryTests: XCTestCase {
    func testDashboardStartKeepsSurvivingActivity() async throws {
        let now = Date()
        let sessions = [AgentSession(id: "dashboard-recovery", agent: .codex,
                                    project: "Dashboard Recovery QA", status: .working,
                                    statusSince: now, updatedAt: now)]
        let original = try Activity.request(attributes: VibeBuddyActivityAttributes(),
            content: ActivityContent(state: VibeBuddyActivityAttributes.ContentState(
                summary: TaskPresentationSummary(sessions: sessions)), staleDate: nil))
        let store = DashboardStore(
            streamer: ScriptedStreamer(snapshots: [Snapshot(sessions: sessions, serverTime: now)]),
            notifier: RecordingNotifier(), decisionClient: NullDecisionClient(),
            watchRelay: nil, reportDevice: { _ in })
        store.start(PairingPayload(host: "127.0.0.1", port: 9, token: "test"))
        let deadline = Date().addingTimeInterval(5)
        while original.content.state.topProject != "Dashboard Recovery QA", Date() < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(original.activityState, .active)
        XCTAssertEqual(original.content.state.topProject, "Dashboard Recovery QA",
                       "Dashboard.start must preserve and update the original activity")
        await store.stop().value
    }

    func testRelaunchReusesActivityAndFreshStopEndsSurvivors() async throws {
        let now = Date()
        let sessions = [AgentSession(id: "activity-recovery", agent: .codex,
                                    project: "Recovery QA", status: .working,
                                    statusSince: now, updatedAt: now)]
        let state = VibeBuddyActivityAttributes.ContentState(
            summary: TaskPresentationSummary(sessions: sessions))
        let original = try Activity.request(attributes: VibeBuddyActivityAttributes(),
                                            content: ActivityContent(state: state, staleDate: nil))
        let duplicate = try Activity.request(attributes: VibeBuddyActivityAttributes(),
                                             content: ActivityContent(state: state, staleDate: nil))
        let ids = Set([original.id, duplicate.id])

        let relaunched = LiveActivityManager()
        await relaunched.sync(sessions: sessions)
        // update() returns before ActivityKit publishes its new content locally.
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            let current = Activity<VibeBuddyActivityAttributes>.activities.filter {
                $0.activityState == .active || $0.activityState == .stale
            }
            if current.count == 1, current.first?.content.state.topProject == "Recovery QA" { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        let live = Activity<VibeBuddyActivityAttributes>.activities.filter {
            $0.activityState == .active || $0.activityState == .stale
        }
        XCTAssertEqual(live.count, 1)
        XCTAssertTrue(live.first.map { ids.contains($0.id) } ?? false,
                      "Relaunch must reuse a surviving activity instead of requesting another")
        XCTAssertEqual(live.first?.content.state.topProject, "Recovery QA")

        // No in-memory handle exists in this manager, just as after process death.
        await LiveActivityManager().end()
        XCTAssertTrue(Activity<VibeBuddyActivityAttributes>.activities.allSatisfy {
            $0.activityState != .active && $0.activityState != .stale
        })
    }
}
