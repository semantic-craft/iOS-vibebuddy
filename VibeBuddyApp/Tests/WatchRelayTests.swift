import XCTest
import VibeBuddyKit
@testable import VibeBuddyApp

@MainActor
private final class FakeWatchTransport: WatchStateTransport {
    var onCompletionRequest: ((WatchCompletionRequest) async -> WatchCompletionResult)?
    var isAvailable = true
    var onReady: (() -> Void)?
    var onApprovalRequest: ((WatchApprovalRequest) async -> WatchApprovalResult)?
    var failNextSends = false
    /// Everything the transport accepted, in order.
    private(set) var sent: [Data] = []
    /// What the mailbox is holding for a Watch that has not read it yet. A send
    /// replaces it, the way writing the application context does.
    private(set) var queued: [Data] = []

    func send(_ payload: Data) throws {
        if failNextSends { throw WatchRelayError.unsupported }
        sent.append(payload)
        queued = [payload]
    }

    var states: [WatchDashboardState] {
        sent.compactMap { try? JSONDecoder().decode(WatchDashboardState.self, from: $0) }
    }

    var queuedStates: [WatchDashboardState] {
        queued.compactMap { try? JSONDecoder().decode(WatchDashboardState.self, from: $0) }
    }

    /// A tap on the wrist, delivered the way WatchConnectivity delivers one.
    func tap(_ request: WatchApprovalRequest) async -> WatchApprovalResult {
        guard let onApprovalRequest else {
            return WatchApprovalResult(attemptId: request.attemptId, outcome: .failed)
        }
        return await onApprovalRequest(request)
    }

    /// The Watch came back. Drive the callback the real session fires.
    func becomeAvailable() {
        isAvailable = true
        failNextSends = false
        onReady?()
    }
}

@MainActor
final class WatchRelayTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func state(working: Int, at offset: TimeInterval = 0,
                       relay: WatchRelayState = .live) -> WatchDashboardState {
        let sessions = (0..<working).map {
            AgentSession(id: "s\($0)", agent: .claudeCode, project: "vibebuddy",
                         status: .working, statusSince: now, updatedAt: now)
        }
        var result = WatchDashboardProjection.make(
            snapshot: Snapshot(sessions: sessions, serverTime: now),
            quotas: [], relay: relay, now: now.addingTimeInterval(offset))
        result.relayRevision = UInt64(100 + offset)
        return result
    }

    func testEquivalentStateIsNotResent() {
        let transport = FakeWatchTransport()
        let relay = WatchRelay(transport: transport)

        XCTAssertTrue(relay.publish(state(working: 1)))
        XCTAssertFalse(relay.publish(state(working: 1, at: 30)))
        XCTAssertTrue(relay.publish(state(working: 1, at: 900)))

        XCTAssertEqual(transport.sent.count, 2)
    }

    func testMeaningfulChangeProducesANewContext() {
        let transport = FakeWatchTransport()
        let relay = WatchRelay(transport: transport)

        relay.publish(state(working: 1))
        relay.publish(state(working: 2))
        relay.publish(state(working: 2, relay: .disconnected))

        XCTAssertEqual(transport.states.map(\.counts.working), [1, 2, 2])
        XCTAssertEqual(transport.states.map(\.relay), [.live, .live, .disconnected])
    }

    func testAnUnavailableWatchGetsOnlyTheNewestStateWhenItReturns() {
        let transport = FakeWatchTransport()
        transport.isAvailable = false
        let relay = WatchRelay(transport: transport)

        relay.publish(state(working: 1))
        relay.publish(state(working: 2))
        relay.publish(state(working: 3))
        XCTAssertEqual(transport.sent.count, 0)

        transport.becomeAvailable()

        XCTAssertEqual(transport.states.map(\.counts.working), [3])
    }

    func testARefusedSendIsRetriedRatherThanLost() {
        let transport = FakeWatchTransport()
        let relay = WatchRelay(transport: transport)

        transport.failNextSends = true
        XCTAssertFalse(relay.publish(state(working: 1)))
        XCTAssertEqual(transport.sent.count, 0)
        XCTAssertNotNil(relay.pending)

        transport.becomeAvailable()

        XCTAssertEqual(transport.states.map(\.counts.working), [1])
        XCTAssertNil(relay.pending)
    }

    func testAStateQueuedWhileUnavailableIsSentEvenIfItMatchesTheLastDelivered() {
        let transport = FakeWatchTransport()
        let relay = WatchRelay(transport: transport)

        relay.publish(state(working: 1))
        transport.isAvailable = false
        relay.publish(state(working: 2))
        transport.becomeAvailable()
        // The Watch went away holding "2"; it must not be left on "1".
        XCTAssertEqual(transport.states.map(\.counts.working), [1, 2])
    }

    func testOnlyTheNewestStateIsLeftWaitingForABackgroundedWatch() {
        let transport = FakeWatchTransport()
        let relay = WatchRelay(transport: transport)

        relay.publish(state(working: 1))
        relay.publish(state(working: 2))
        relay.publish(state(working: 3))

        // Three states were handed over, but a Watch that reads the mailbox now
        // draws the third one once instead of replaying two obsolete screens.
        XCTAssertEqual(transport.states.map(\.counts.working), [1, 2, 3])
        XCTAssertEqual(transport.queuedStates.map(\.counts.working), [3])
    }

    func testDeliveriesArrivingOutOfOrderLeaveTheNewestOnScreen() {
        let transport = FakeWatchTransport()
        let relay = WatchRelay(transport: transport)

        relay.publish(state(working: 1))
        relay.publish(state(working: 2, at: 30))

        var inbox = WatchStateInbox()
        for payload in transport.sent.reversed() { inbox.accept(payload) }

        XCTAssertEqual(inbox.state?.counts.working, 2)
    }

    func testDemoModeRelaysSampleStateWithQuota() {
        let transport = FakeWatchTransport()
        let store = DashboardStore(streamer: EmptyStreamer(), notifier: SilentNotifier(),
                                   decisionClient: NullDecisionClient(),
                                   watchRelay: WatchRelay(transport: transport))
        store.startDemo()

        let relayed = transport.states.last
        XCTAssertEqual(relayed?.isDemo, true)
        XCTAssertEqual(relayed?.relay, .live)
        XCTAssertEqual(relayed?.counts.needsResponse, 3)
        XCTAssertEqual(relayed?.counts.working, 3)
        XCTAssertEqual(relayed?.counts.done, 3)
        XCTAssertEqual(relayed?.stuck, 1)
        XCTAssertEqual(relayed?.quotas.count, 2)
        store.stop()
    }

    func testResolvingADemoApprovalRelaysTheNewState() throws {
        let transport = FakeWatchTransport()
        let store = DashboardStore(streamer: EmptyStreamer(), notifier: SilentNotifier(),
                                   decisionClient: NullDecisionClient(),
                                   watchRelay: WatchRelay(transport: transport))
        store.startDemo()
        let approvalId = try XCTUnwrap(store.allSessions.compactMap(\.pendingApproval).first).id

        store.decide(approvalId, .allow)

        XCTAssertEqual(transport.states.count, 2)
        XCTAssertEqual(transport.states.last?.counts.needsResponse, 2)
        store.stop()
    }

    func testRelayedPayloadCarriesNoPairingSecretsOrSessionCollection() {
        let transport = FakeWatchTransport()
        let store = DashboardStore(streamer: EmptyStreamer(), notifier: SilentNotifier(),
                                   decisionClient: NullDecisionClient(),
                                   watchRelay: WatchRelay(transport: transport))
        store.start(PairingPayload(host: "10.0.0.7", port: 9876, token: "s3cr3t-bearer"))
        store.startDemo()

        let json = String(decoding: transport.sent.last ?? Data(), as: UTF8.self)
        for secret in ["10.0.0.7", "9876", "s3cr3t-bearer", "iTerm", "todos.sort", "\"sessions\""] {
            XCTAssertFalse(json.contains(secret), "relay payload leaked \(secret)")
        }
        store.stop()
    }

    // MARK: - Decisions coming back from the wrist

    /// The wrist's view of the world, taken from what was actually relayed —
    /// never from the store's internals, because that is all the Watch has.
    private func relayedAlert(_ transport: FakeWatchTransport,
                              decidable: Bool) throws -> WatchAlert {
        let state = try XCTUnwrap(transport.states.last)
        return try XCTUnwrap(state.alerts.first { $0.isDecidable == decidable })
    }

    private func demoStore(_ transport: FakeWatchTransport,
                           decisions: DecisionClient = NullDecisionClient()) -> DashboardStore {
        let store = DashboardStore(streamer: EmptyStreamer(), notifier: SilentNotifier(),
                                   decisionClient: decisions,
                                   watchRelay: WatchRelay(transport: transport))
        store.startDemo()
        return store
    }

    func testAWatchApprovalResolvesTheApprovalAndReportsAccepted() async throws {
        let transport = FakeWatchTransport()
        let store = demoStore(transport)
        let alert = try relayedAlert(transport, decidable: true)
        let approvalId = try XCTUnwrap(alert.approvalId)

        let result = await transport.tap(WatchApprovalRequest(
            attemptId: "t-1", sessionId: alert.sessionId,
            approvalId: approvalId, choice: .allow))

        XCTAssertEqual(result, WatchApprovalResult(attemptId: "t-1", outcome: .accepted))
        XCTAssertFalse(store.allSessions.contains { $0.pendingApproval?.id == approvalId })
        store.stop()
    }

    func testARepeatedTapIsNotResubmitted() async throws {
        let transport = FakeWatchTransport()
        let store = demoStore(transport)
        let alert = try relayedAlert(transport, decidable: true)
        let request = WatchApprovalRequest(attemptId: "t-1", sessionId: alert.sessionId,
                                           approvalId: try XCTUnwrap(alert.approvalId),
                                           choice: .allow)

        _ = await transport.tap(request)
        let relayCount = transport.sent.count
        let repeated = await transport.tap(request)

        // Still accepted — the tap did land — but nothing moved a second time.
        XCTAssertEqual(repeated.outcome, .accepted)
        XCTAssertEqual(transport.sent.count, relayCount, "a duplicate tap re-projected nothing")
        store.stop()
    }

    func testATapForAnApprovalThatMovedOnIsRefused() async throws {
        let transport = FakeWatchTransport()
        let store = demoStore(transport)
        let alert = try relayedAlert(transport, decidable: true)

        let stale = await transport.tap(WatchApprovalRequest(
            attemptId: "t-1", sessionId: alert.sessionId,
            approvalId: "an-approval-that-already-resolved", choice: .allow))
        XCTAssertEqual(stale.outcome, .refused)

        let wrongSession = await transport.tap(WatchApprovalRequest(
            attemptId: "t-2", sessionId: "demo-work",
            approvalId: try XCTUnwrap(alert.approvalId), choice: .allow))
        XCTAssertEqual(wrongSession.outcome, .refused)
        store.stop()
    }

    func testTheRichEditApprovalCannotBeResolvedFromTheWrist() async throws {
        let transport = FakeWatchTransport()
        let store = demoStore(transport)
        let displayOnly = try relayedAlert(transport, decidable: false)
        // Its real approval id, taken from the phone — the Watch was never told it.
        let hidden = try XCTUnwrap(store.allSessions
            .first { $0.id == displayOnly.sessionId }?.pendingApproval?.id)

        let result = await transport.tap(WatchApprovalRequest(
            attemptId: "t-1", sessionId: displayOnly.sessionId,
            approvalId: hidden, choice: .allow))

        XCTAssertEqual(result.outcome, .refused)
        XCTAssertTrue(store.allSessions.contains { $0.pendingApproval?.id == hidden })
        store.stop()
    }

    func testAnUnreachableMacReportsFailedAndTheTapCanBeMadeAgain() async throws {
        let transport = FakeWatchTransport()
        let decisions = UnreachableDecisionClient()
        let sampleStore = demoStore(FakeWatchTransport())
        let samples = sampleStore.allSessions
        sampleStore.stop()
        let store = DashboardStore(
            streamer: ScriptedStreamer(snapshots: [Snapshot(sessions: samples, serverTime: Date())]),
            notifier: SilentNotifier(), decisionClient: decisions,
            watchRelay: WatchRelay(transport: transport), reportDevice: { _ in })
        // An authenticated snapshot supplies the waiting task. Switching from
        // sample data to a pairing intentionally clears the previous source.
        store.start(PairingPayload(host: "127.0.0.1", port: 9, token: "test"))
        for _ in 0..<50 {
            if !store.allSessions.isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let alert = try relayedAlert(transport, decidable: true)
        let request = WatchApprovalRequest(attemptId: "t-1", sessionId: alert.sessionId,
                                           approvalId: try XCTUnwrap(alert.approvalId),
                                           choice: .allow)

        let first = await transport.tap(request)
        XCTAssertEqual(first.outcome, .failed)
        // Not remembered as handled, so the user can try the same tap again.
        let second = await transport.tap(request)
        XCTAssertEqual(second.outcome, .failed)
        let attempts = await decisions.attempts
        XCTAssertEqual(attempts, 2)
        store.stop()
    }
}
