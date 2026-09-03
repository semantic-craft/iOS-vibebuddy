import Testing
import Foundation
@testable import VibeBuddyKit

/// The Watch has to name the innermost link it can prove is down, from a
/// relayed field, its own clock, and its own view of the phone.
@Suite("Watch connection layers")
struct WatchConnectionTests {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let stale = WatchDashboardState.staleAfter

    private func state(_ relay: WatchRelayState, sentAgo: TimeInterval = 0) -> WatchDashboardState {
        guard relay != .noData else { return .noData(observedAt: now.addingTimeInterval(-sentAgo)) }
        let session = AgentSession(id: "s1", agent: .claudeCode, project: "vibebuddy",
                                   status: .working, statusSince: now, updatedAt: now)
        return WatchDashboardProjection.make(
            snapshot: Snapshot(sessions: [session], serverTime: now),
            quotas: [], relay: relay, now: now.addingTimeInterval(-sentAgo))
    }

    @Test("A fresh relay from a connected iPhone is live")
    func liveIsLive() {
        #expect(state(.live).connection(now: now, phoneReachable: true) == .live)
    }

    @Test("A fresh relay whose iPhone lost the Mac names the Mac")
    func macDisconnectedIsItsOwnLayer() {
        #expect(state(.disconnected).connection(now: now, phoneReachable: true) == .macDisconnected)
    }

    @Test("Nothing for the stale window, with the iPhone in range, names the iPhone")
    func silentPhoneIsItsOwnLayer() {
        let aged = state(.live, sentAgo: stale + 60)
        #expect(aged.connection(now: now, phoneReachable: true) == .phoneDisconnected)
    }

    @Test("Nothing for the stale window with no iPhone in range names the Watch's own link")
    func lostPhoneIsItsOwnLayer() {
        let aged = state(.live, sentAgo: stale + 60)
        #expect(aged.connection(now: now, phoneReachable: false) == .watchUnreachable)
    }

    @Test("The three failures are three different labels")
    func everyLayerIsDistinct() {
        let layers: Set<WatchConnection> = [
            state(.disconnected).connection(now: now, phoneReachable: true),
            state(.live, sentAgo: stale + 60).connection(now: now, phoneReachable: true),
            state(.live, sentAgo: stale + 60).connection(now: now, phoneReachable: false),
            state(.noData).connection(now: now, phoneReachable: true),
        ]
        #expect(layers.count == 4)
        #expect(!layers.contains(.live))
    }

    @Test("A momentarily out-of-range Watch holding a fresh state is still live")
    func freshStateSurvivesAMomentaryDrop() {
        #expect(state(.live, sentAgo: 30).connection(now: now, phoneReachable: false) == .live)
    }

    @Test("Age wins over the relayed verdict: an old 'connected' is not a claim about now")
    func stalenessOutranksTheRelayedField() {
        let aged = state(.disconnected, sentAgo: stale + 60)
        #expect(aged.connection(now: now, phoneReachable: true) == .phoneDisconnected)
    }

    @Test("No data stays no data however old it is")
    func noDataIsNeverAConnectionFailure() {
        #expect(state(.noData, sentAgo: stale * 4).connection(now: now, phoneReachable: false) == .noData)
    }

    @Test("The same state crosses the 15-minute boundary with no new message")
    func staleTransitionNeedsNoDelivery() {
        let delivered = state(.live)
        #expect(WatchDashboardState.staleAfter == 15 * 60)
        #expect(!delivered.isStale(now: now.addingTimeInterval(stale - 1)))
        #expect(delivered.connection(now: now.addingTimeInterval(stale - 1), phoneReachable: true) == .live)
        #expect(delivered.isStale(now: now.addingTimeInterval(stale)))
        #expect(delivered.connection(now: now.addingTimeInterval(stale), phoneReachable: true) == .phoneDisconnected)
    }

    @Test("A state restored from disk ages against the current clock, not its own")
    func restoredStateGoesStaleOnItsOwn() throws {
        var inbox = WatchStateInbox()
        inbox.accept(WatchStateInbox.encode(state(.live)))
        let restored = try #require(inbox.state)

        // Cold launch an hour later: nothing new arrived, and it must not claim
        // to be live just because it is the newest thing this Watch holds.
        let coldLaunch = now.addingTimeInterval(3_600)
        #expect(restored.connection(now: coldLaunch, phoneReachable: true) == .phoneDisconnected)
        #expect(restored.connection(now: coldLaunch, phoneReachable: false) == .watchUnreachable)
    }

    @Test("Provider freshness stays independent of the connection state")
    func quotaFreshnessIsNotTheConnection() {
        let quotas = [
            ProviderQuota(provider: .codex, weeklyRemainingPercent: 60, observedAt: now),
            ProviderQuota.unavailable(.claude, reason: "Claude is signed out"),
        ]
        let projected = WatchDashboardProjection.make(
            snapshot: Snapshot(sessions: [], serverTime: now),
            quotas: quotas, relay: .disconnected, now: now)

        #expect(projected.connection(now: now, phoneReachable: true) == .macDisconnected)
        #expect(projected.quota(.codex)?.freshness(now: now) == .live)
        #expect(projected.quota(.claude)?.freshness(now: now) == .unavailable)
    }

    @Test("Every demo scenario renders the layer it is named after")
    func demoScenariosCoverEveryLayer() {
        let expected: [WatchDemoScenario: WatchConnection] = [
            .normal: .live,
            .macDisconnected: .macDisconnected,
            .phoneDisconnected: .phoneDisconnected,
            .watchUnreachable: .watchUnreachable,
            .noData: .noData,
        ]
        for (scenario, connection) in expected {
            let state = scenario.state(now: now)
            #expect(state.connection(now: now, phoneReachable: scenario.phoneReachable) == connection,
                    "\(scenario.rawValue) should read as \(connection.rawValue)")
        }
    }
}
