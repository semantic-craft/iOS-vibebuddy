import XCTest
import VibeBuddyKit
@testable import VibeBuddyApp

private actor DecisionRecorder: DecisionClient {
    private(set) var acknowledgedSessionIDs: [String] = []
    private(set) var attentions: [(sessionId: String, level: SessionAttention?)] = []

    func acknowledge(_ pairing: PairingPayload, sessionId: String) async {
        acknowledgedSessionIDs.append(sessionId)
    }

    func setAttention(_ pairing: PairingPayload, sessionId: String, level: SessionAttention?) async {
        attentions.append((sessionId, level))
    }

    func decide(_ pairing: PairingPayload, approvalId: String, decision: ApprovalDecision) async -> Bool { true }
    func answer(_ pairing: PairingPayload, sessionId: String, answer: String) async {}
    func jump(_ pairing: PairingPayload, sessionId: String) async -> JumpOutcome? { nil }
}

private actor ActionRecorder: DecisionClient {
    private(set) var submits: [SessionActionRequest] = []

    func acknowledge(_ pairing: PairingPayload, sessionId: String) async {}
    func setAttention(_ pairing: PairingPayload, sessionId: String, level: SessionAttention?) async {}
    func decide(_ pairing: PairingPayload, approvalId: String, decision: ApprovalDecision) async -> Bool { true }
    func answer(_ pairing: PairingPayload, sessionId: String, answer: String) async {}
    func jump(_ pairing: PairingPayload, sessionId: String) async -> JumpOutcome? { nil }
    func submitSessionAction(_ pairing: PairingPayload, request: SessionActionRequest) async -> SessionActionOutcome {
        submits.append(request)
        return .accepted
    }
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
        XCTAssertEqual(store.allSessions.first?.effectiveAttention, .normal)

        store.setAttention("s", .followed)
        XCTAssertEqual(store.allSessions.first?.effectiveAttention, .followed)
        XCTAssertEqual(store.allSessions.first?.attentionOverride, .followed)
        for _ in 0..<50 {
            if !(await decisions.attentions).isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let sent = await decisions.attentions
        XCTAssertEqual(sent.map(\.sessionId), ["s"])
        XCTAssertEqual(sent.map(\.level), [.followed])
        store.stop()
    }

    /// The Mac's device registry can be emptied by a Mac restart while this app
    /// is only backgrounded. Reporting once per launch left the Mac unable to
    /// push until the phone next cold-launched; every reconnect must repair it.
    func testDisconnectedActionIsNotSent() async throws {
        let decisions = ActionRecorder()
        let store = DashboardStore(streamer: EmptyStreamer(), notifier: SilentNotifier(),
                                   decisionClient: decisions, watchRelay: nil)
        store.start(PairingPayload(host: "127.0.0.1", port: 9, token: "test"))
        let outcome = await store.submitAction(sessionId: "s", text: "keep going")
        XCTAssertEqual(outcome, .notSent("Couldn't reach your Mac — not sent"))
        let sentWhileDisconnected = await decisions.submits
        XCTAssertEqual(sentWhileDisconnected.count, 0)
        store.stop()
    }

    func testDemoCodexSteerIsAcceptedNotWorking() async throws {
        let decisions = ActionRecorder()
        let store = DashboardStore(streamer: EmptyStreamer(), notifier: SilentNotifier(),
                                   decisionClient: decisions, watchRelay: nil)
        store.startDemo()
        let outcome = await store.submitAction(sessionId: "demo-work", text: "also run the tests")
        XCTAssertEqual(outcome, .accepted)
        XCTAssertEqual(store.toast, DashboardStore.actionMessage(.accepted))
        let sentInDemo = await decisions.submits
        XCTAssertEqual(sentInDemo.count, 0)
        store.stop()
    }

    /// The Mac's device registry can be emptied by a Mac restart while this app
    /// is only backgrounded. Reporting once per launch left the Mac unable to
    /// push until the phone next cold-launched; every reconnect must repair it.
    func testEveryReconnectReReportsTheDeviceToTheMac() async throws {
        var reports: [PairingPayload] = []
        let store = DashboardStore(
            streamer: EmptyStreamer(),      // finishes at once → the reconnect loop
            notifier: SilentNotifier(), decisionClient: NullDecisionClient(),
            watchRelay: nil, reportDevice: { reports.append($0) })

        let pairing = PairingPayload(host: "127.0.0.1", port: 9, token: "test")
        store.start(pairing)
        for _ in 0..<500 {
            if reports.count >= 2 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        store.stop()

        XCTAssertGreaterThanOrEqual(reports.count, 2)
        XCTAssertEqual(reports.first?.host, "127.0.0.1")
    }
}
