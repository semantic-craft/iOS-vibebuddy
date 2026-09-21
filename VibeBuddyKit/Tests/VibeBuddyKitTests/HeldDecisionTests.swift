import XCTest
@testable import VibeBuddyKit

/// The 2026-09-22 night, as rules: the phone must name the missing link,
/// hold a decision it cannot deliver, retry it under one key, and let the
/// wrist say "holding" rather than nothing.
final class HeldDecisionTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let tailnet = CompanionEndpoint(host: "100.100.0.7", port: 9876)!
    private let lan = CompanionEndpoint(host: "192.0.2.10", port: 9876)!

    // MARK: Diagnosis

    func testTailnetPairingWithoutTunnelNamesSurgeOff() {
        let reason = ConnectionDiagnosis.diagnose(endpoint: tailnet, kind: .unreachable, phoneHasTailnet: false)
        XCTAssertEqual(reason, .tailnetOff(host: "100.100.0.7"))
        XCTAssertTrue(reason.needsTailnet)
        XCTAssertTrue(reason.isRetryable)
        // The tunnel dropping under an open socket is the same story.
        XCTAssertEqual(ConnectionDiagnosis.diagnose(endpoint: tailnet, kind: .dropped, phoneHasTailnet: false),
                       .tailnetOff(host: "100.100.0.7"))
    }

    func testTailnetPairingWithTunnelIsTheMac() {
        XCTAssertEqual(ConnectionDiagnosis.diagnose(endpoint: tailnet, kind: .unreachable, phoneHasTailnet: true),
                       .macUnreachable(host: "100.100.0.7"))
        XCTAssertEqual(ConnectionDiagnosis.diagnose(endpoint: tailnet, kind: .dropped, phoneHasTailnet: true), .dropped)
    }

    func testLANPairingNeverBlamesTheTunnel() {
        XCTAssertEqual(ConnectionDiagnosis.diagnose(endpoint: lan, kind: .unreachable, phoneHasTailnet: false),
                       .macUnreachable(host: "192.0.2.10"))
        XCTAssertEqual(ConnectionDiagnosis.diagnose(endpoint: lan, kind: .authentication, phoneHasTailnet: false),
                       .authentication)
        XCTAssertFalse(ConnectionFailureReason.authentication.isRetryable)
        XCTAssertEqual(ConnectionDiagnosis.diagnose(endpoint: nil, kind: .unreachable, phoneHasTailnet: true),
                       .invalidAddress)
    }

    // MARK: Queue

    private func approve(_ id: String, approvalId: String = "ap-1", choice: WatchApprovalChoice = .allow,
                         epoch: String = "e1", at offset: TimeInterval = 0) -> QueuedSessionAction {
        QueuedSessionAction(id: id, sessionId: "s1", action: .approval(id: approvalId, choice: choice),
                            origin: .watch, pairingEpoch: epoch, queuedAt: now.addingTimeInterval(offset))
    }

    func testLaterDecisionOnSameTargetSupersedesEarlier() {
        var queue = SessionActionQueue()
        XCTAssertNil(queue.hold(approve("a")))
        let replaced = queue.hold(approve("b", choice: .deny))
        XCTAssertEqual(replaced?.id, "a")
        XCTAssertEqual(queue.items.map(\.id), ["b"])
        XCTAssertEqual(queue.held(approvalId: "ap-1")?.choice, .deny)
        // A different approval sits beside it.
        queue.hold(approve("c", approvalId: "ap-2"))
        XCTAssertEqual(queue.count, 2)
    }

    func testStopIsNeverHeld() {
        var queue = SessionActionQueue()
        let stop = QueuedSessionAction(id: "x", sessionId: "s1", action: .stop(statusSince: now),
                                       origin: .watch, pairingEpoch: "e1", queuedAt: now)
        XCTAssertFalse(stop.isHoldable)
        queue.hold(stop)
        XCTAssertTrue(queue.isEmpty)
    }

    func testPruneDropsOtherEpochsOldAndExhausted() {
        var queue = SessionActionQueue()
        queue.hold(approve("fresh"))
        queue.hold(approve("old", approvalId: "ap-old", at: -SessionActionQueue.maxAge - 1))
        queue.hold(approve("repaired", approvalId: "ap-re", epoch: "e0"))
        queue.hold(approve("tired", approvalId: "ap-tired"))
        for _ in 0..<SessionActionQueue.maxAttempts { queue.noteAttempt(id: "tired", reason: .dropped) }
        let dropped = queue.prune(now: now, epoch: "e1")
        XCTAssertEqual(Set(dropped.map(\.id)), ["old", "repaired", "tired"])
        XCTAssertEqual(queue.items.map(\.id), ["fresh"])
    }

    func testWatchProjectionIsScopedToThePairing() {
        var queue = SessionActionQueue()
        queue.hold(approve("a"))
        queue.hold(approve("b", approvalId: "ap-9", epoch: "other"))
        let held = queue.watchProjection(epoch: "e1")
        XCTAssertEqual(held.map(\.id), ["a"])
        XCTAssertEqual(held.first?.approvalId, "ap-1")
        XCTAssertEqual(held.first?.choice, .allow)
    }

    func testQueueRoundTripsThroughJSON() throws {
        var queue = SessionActionQueue()
        var item = approve("a")
        item.lastReason = .tailnetOff(host: "100.100.0.7")
        item.project = "ios-vibebuddy"
        item.agent = .cursor
        queue.hold(item)
        let data = try JSONEncoder().encode(queue)
        let decoded = try JSONDecoder().decode(SessionActionQueue.self, from: data)
        XCTAssertEqual(decoded, queue)
    }

    // MARK: Wrist

    private func alertState(heldIDs: [String]?) -> WatchDashboardState {
        let alert = WatchAlert(sessionId: "s1", agent: .cursor, project: "p", waitKind: .permission,
                               tool: "Bash", request: "swift test", approvalId: "ap-1",
                               handling: .watchApproval, waitingSince: now)
        return WatchDashboardState(sourceID: "mac", pairingEpoch: "e1", alerts: [alert],
                                   relay: .disconnected, observedAt: now,
                                   heldActions: heldIDs?.map {
                                       WatchHeldAction(id: $0, sessionId: "s1", approvalId: "ap-1",
                                                       choice: .allow, heldSince: now)
                                   })
    }

    func testQueuedReplyIsAHeldPhaseWithItsReason() throws {
        var state = WatchSessionActionState()
        let alert = try XCTUnwrap(alertState(heldIDs: nil).alerts.first)
        let request = try XCTUnwrap(state.begin(alert: alert, choice: .allow, attemptId: "t1"))
        state.apply(WatchSessionActionResult(attemptId: request.attemptId, outcome: .queued,
                                             reason: .tailnetOff(host: "100.100.0.7")))
        XCTAssertEqual(state.action?.phase, .queued)
        XCTAssertEqual(state.action?.reason, .tailnetOff(host: "100.100.0.7"))
        // Not busy: the person may change their mind, the phone supersedes.
        XCTAssertFalse(state.isBusy)
        // Still held on the next relay: keep saying so.
        state.reconcile(with: alertState(heldIDs: ["t1"]))
        XCTAssertEqual(state.action?.phase, .queued)
        // The phone stopped holding it while the request still waits.
        state.reconcile(with: alertState(heldIDs: []))
        XCTAssertEqual(state.action?.phase, .failed)
        // A relay without the field says nothing about it.
        var again = WatchSessionActionState()
        _ = again.begin(alert: alert, choice: .allow, attemptId: "t2")
        again.apply(WatchSessionActionResult(attemptId: "t2", outcome: .queued))
        again.reconcile(with: alertState(heldIDs: nil))
        XCTAssertEqual(again.action?.phase, .queued)
    }

    func testOlderResultWireStillDecodes() throws {
        let legacy = Data(#"{"attemptId":"t","outcome":"failed"}"#.utf8)
        let result = try JSONDecoder().decode(WatchSessionActionResult.self, from: legacy)
        XCTAssertEqual(result.outcome, .failed)
        XCTAssertNil(result.reason)
    }
}
