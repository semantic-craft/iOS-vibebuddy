import XCTest
import VibeBuddyKit
@testable import VibeBuddyApp

/// The iPhone is the only device that schedules a notification; watchOS mirrors
/// what it posts. These assert the two halves that keeps honest: one banner per
/// cue, and no banner outliving the wait it describes.
@MainActor
final class NotificationRelayTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func session(_ id: String, _ status: SessionStatus, at offset: TimeInterval) -> AgentSession {
        AgentSession(id: id, agent: .claudeCode, project: "vibebuddy",
                     status: status,
                     waitKind: status == .needsResponse ? .permission : nil,
                     pendingApproval: status == .needsResponse
                        ? PendingApproval(id: "ap-\(id)", tool: "Bash", commandPreview: "swift test")
                        : nil,
                     summary: "a summary",
                     statusSince: now.addingTimeInterval(offset),
                     updatedAt: now.addingTimeInterval(offset))
    }

    private func run(_ snapshots: [[AgentSession]]) async -> RecordingNotifier {
        let applied = expectation(description: "All snapshots reached notification reconciliation")
        applied.expectedFulfillmentCount = snapshots.count
        let notifier = RecordingNotifier(onWithdrawal: { applied.fulfill() })
        let store = DashboardStore(
            streamer: ScriptedStreamer(snapshots: snapshots.map { Snapshot(sessions: $0, serverTime: now) }),
            notifier: notifier,
            decisionClient: NullDecisionClient(),
            watchRelay: nil, reportDevice: { _ in })
        store.start(PairingPayload(host: "127.0.0.1", port: 9, token: "test"))
        // Wait for actual notification reconciliation, not a 200 ms scheduling guess.
        await fulfillment(of: [applied], timeout: 10)
        store.stop()
        return notifier
    }

    func testAWaitIsAnnouncedOnceAndTakenBackWhenItIsAnswered() async {
        let notifier = await run([
            [session("s1", .working, at: -60)],
            [session("s1", .needsResponse, at: -1)],
            [session("s1", .working, at: 0)],
        ])

        XCTAssertEqual(notifier.posted, ["s1-needs_approval"])
        XCTAssertEqual(notifier.withdrawn, ["s1-needs_approval"])
    }

    func testAStillWaitingSessionKeepsItsNotification() async {
        let notifier = await run([
            [session("s1", .working, at: -60)],
            [session("s1", .needsResponse, at: -1)],
            [session("s1", .needsResponse, at: -1)],
        ])

        XCTAssertEqual(notifier.posted, ["s1-needs_approval"])
        XCTAssertEqual(notifier.withdrawn, [])
    }

    func testASessionThatVanishesTakesItsNotificationWithIt() async {
        let notifier = await run([
            [session("s1", .working, at: -60)],
            [session("s1", .needsResponse, at: -1)],
            [],
        ])

        XCTAssertEqual(notifier.withdrawn, ["s1-needs_approval"])
    }

    func testRepeatedSnapshotsOfTheSameWaitDoNotStackNotifications() async {
        let waiting = session("s1", .needsResponse, at: -1)
        let notifier = await run([
            [session("s1", .working, at: -60)],
            [waiting], [waiting], [waiting],
        ])

        XCTAssertEqual(notifier.posted, ["s1-needs_approval"])
    }

    /// The Watch app must never schedule anything of its own: a second scheduler
    /// is a duplicate by construction, and it would have to re-derive the
    /// `needsResponse` boundary and the sound preference from a projection that
    /// deliberately does not carry them. (The projection does now carry the
    /// notification switches and the Quiet *settings*, so the wrist can mute its
    /// own haptics — muting what it already has, not deciding a new cue.)
    func testDemoPostsApprovalAndQuestionBanners() async throws {
        let notifier = RecordingNotifier()
        let store = DashboardStore(
            streamer: EmptyStreamer(),
            notifier: notifier,
            decisionClient: NullDecisionClient(),
            watchRelay: nil)
        store.startDemo()
        for _ in 0..<100 where notifier.posted.count < 2 {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(notifier.posted.contains("demo-edit-needs_approval"))
        XCTAssertTrue(notifier.posted.contains("demo-question-needs_answer"))
    }

    /// Reading a notification that has already been delivered is a different
    /// thing from scheduling one, and the Watch's long look has to do it: a
    /// `WKUserNotificationHostingController` is handed a `UNNotification` and
    /// that type lives in `UserNotifications`. So the ban is on the scheduler
    /// itself — `UNUserNotificationCenter` and `UNNotificationRequest` — rather
    /// than on the import. Nothing on the wrist may add, withdraw, or ask
    /// permission for a notification.
    func testTheWatchTargetSchedulesNoNotificationsOfItsOwn() throws {
        let watch = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // VibeBuddyApp
            .appendingPathComponent("Watch")
        let sources = try FileManager.default
            .contentsOfDirectory(at: watch, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        XCTAssertFalse(sources.isEmpty)

        for source in sources {
            let text = try String(contentsOf: source, encoding: .utf8)
            XCTAssertFalse(text.contains("UNUserNotificationCenter"),
                           "\(source.lastPathComponent) touches the notification centre")
            XCTAssertFalse(text.contains("UNNotificationRequest"),
                           "\(source.lastPathComponent) schedules a notification")
        }
    }
}
