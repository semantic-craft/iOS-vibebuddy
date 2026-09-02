import XCTest
import VibeBuddyKit
@testable import VibeBuddyApp

private actor DecisionRecorder: DecisionClient {
    private(set) var acknowledgedSessionIDs: [String] = []

    func acknowledge(_ pairing: PairingPayload, sessionId: String) async {
        acknowledgedSessionIDs.append(sessionId)
    }

    func decide(_ pairing: PairingPayload, approvalId: String, decision: ApprovalDecision) async {}
    func answer(_ pairing: PairingPayload, sessionId: String, answer: String) async {}
    func jump(_ pairing: PairingPayload, sessionId: String) async -> JumpOutcome? { nil }
}

private struct EmptyStreamer: SnapshotStreaming {
    func stream(_ pairing: PairingPayload) -> AsyncStream<Snapshot> {
        AsyncStream { $0.finish() }
    }
}

private struct SilentNotifier: AttentionNotifier {
    func requestAuthorization() {}
    func notify(_ alert: SoundAlert) {}
    func confirmPairing() {}
}

@MainActor
final class DashboardStoreTests: XCTestCase {
    func testColdStartDeepLinkReplaysAcknowledgementAfterPairingStarts() async throws {
        let decisions = DecisionRecorder()
        let store = DashboardStore(streamer: EmptyStreamer(), notifier: SilentNotifier(),
                                   decisionClient: decisions)

        store.open(VibeBuddyDeepLink.sessionURL(id: "completed-task"))
        let beforeStart = await decisions.acknowledgedSessionIDs
        XCTAssertEqual(beforeStart, [])

        store.start(PairingPayload(host: "127.0.0.1", port: 9, token: "test"))
        for _ in 0..<50 {
            if !(await decisions.acknowledgedSessionIDs).isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }

        let afterStart = await decisions.acknowledgedSessionIDs
        XCTAssertEqual(afterStart, ["completed-task"])
        store.stop()
    }
}
