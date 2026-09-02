import XCTest
import VibeBuddyKit
@testable import VibeBuddyApp

@MainActor
private final class FakeWatchTransport: WatchStateTransport {
    var isAvailable = true
    var onReady: (() -> Void)?
    var failNextSends = false
    private(set) var sent: [Data] = []

    func send(_ payload: Data) throws {
        if failNextSends { throw WatchRelayError.unsupported }
        sent.append(payload)
    }

    var states: [WatchDashboardState] {
        sent.compactMap { try? JSONDecoder().decode(WatchDashboardState.self, from: $0) }
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
        return WatchDashboardProjection.make(
            snapshot: Snapshot(sessions: sessions, serverTime: now),
            quotas: [], relay: relay, now: now.addingTimeInterval(offset))
    }

    func testEquivalentStateIsNotResent() {
        let transport = FakeWatchTransport()
        let relay = WatchRelay(transport: transport)

        XCTAssertTrue(relay.publish(state(working: 1)))
        XCTAssertFalse(relay.publish(state(working: 1, at: 30)))
        XCTAssertFalse(relay.publish(state(working: 1, at: 900)))

        XCTAssertEqual(transport.sent.count, 1)
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

    func testDemoModeRelaysSampleStateWithQuota() {
        let transport = FakeWatchTransport()
        let store = DashboardStore(streamer: EmptyStreamer(), notifier: SilentNotifier(),
                                   decisionClient: NullDecisionClient(),
                                   watchRelay: WatchRelay(transport: transport))
        store.startDemo()

        let relayed = transport.states.last
        XCTAssertEqual(relayed?.isDemo, true)
        XCTAssertEqual(relayed?.relay, .live)
        XCTAssertEqual(relayed?.counts.needsResponse, 2)
        XCTAssertEqual(relayed?.counts.working, 2)
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
        XCTAssertEqual(transport.states.last?.counts.needsResponse, 1)
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
}
