import XCTest
import VibeBuddyKit
@testable import VibeBuddyApp

private actor DecisionRecorder: DecisionClient {
    private(set) var acknowledgedSessionIDs: [String] = []
    private(set) var follows: [(sessionId: String, followed: Bool)] = []

    func acknowledge(_ pairing: PairingPayload, sessionId: String) async {
        acknowledgedSessionIDs.append(sessionId)
    }

    func follow(_ pairing: PairingPayload, sessionId: String, followed: Bool) async {
        follows.append((sessionId, followed))
    }

    func decide(_ pairing: PairingPayload, approvalId: String, decision: ApprovalDecision) async -> Bool { true }
    func answer(_ pairing: PairingPayload, sessionId: String, answer: String) async {}
    func jump(_ pairing: PairingPayload, sessionId: String) async -> JumpOutcome? { nil }
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

    func testFollowFlipsTheRowAtOnceAndTellsTheMac() async throws {
        let decisions = DecisionRecorder()
        let t = Date(timeIntervalSince1970: 0)
        let working = AgentSession(id: "s", agent: .claudeCode, project: "p",
                                   status: .working, statusSince: t, updatedAt: t)
        let store = DashboardStore(
            streamer: ScriptedStreamer(snapshots: [Snapshot(sessions: [working], serverTime: t)]),
            notifier: SilentNotifier(), decisionClient: decisions, watchRelay: nil)
        store.start(PairingPayload(host: "127.0.0.1", port: 9, token: "test"))
        for _ in 0..<50 {
            if !store.allSessions.isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(store.allSessions.first?.isFollowed, false)

        store.setFollowed("s", true)
        XCTAssertEqual(store.allSessions.first?.isFollowed, true)
        for _ in 0..<50 {
            if !(await decisions.follows).isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let sent = await decisions.follows
        XCTAssertEqual(sent.map(\.sessionId), ["s"])
        XCTAssertEqual(sent.map(\.followed), [true])
        store.stop()
    }
}
