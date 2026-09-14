import XCTest
import UserNotifications
import VibeBuddyKit
@testable import VibeBuddyApp

@MainActor
final class NotificationQATests: XCTestCase {
    func testQAAlertLeavesFreshInstallAuthorizationUndetermined() async throws {
        let center = UNUserNotificationCenter.current()
        let before = await center.notificationSettings()
        try XCTSkipIf(before.authorizationStatus != .notDetermined,
                      "Run on a fresh simulator to verify that posting does not request permission.")
        let key = "VIBEBUDDY_SKIP_NOTIFICATIONS"
        let previous = ProcessInfo.processInfo.environment[key]
        setenv(key, "1", 1)
        defer {
            if let previous { setenv(key, previous, 1) }
            else { unsetenv(key) }
        }
        let session = AgentSession(id: "qa-no-prompt-\(UUID().uuidString)", agent: .codex,
                                   project: "QA", status: .needsResponse,
                                   statusSince: Date(), updatedAt: Date())
        let posted = await LocalNotifier().notify(SoundAlert(session: session, sound: .needsApproval))
        XCTAssertFalse(posted)
        let after = await center.notificationSettings()
        XCTAssertEqual(after.authorizationStatus, .notDetermined)
    }
}
