import Testing
import Foundation
@testable import VibeBuddyKit

@Suite("Watch complication projection")
struct WatchComplicationTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func session(_ id: String, _ status: SessionStatus,
                         waitKind: WaitKind? = nil) -> AgentSession {
        AgentSession(
            id: id, agent: .claudeCode, project: "vibebuddy",
            status: status, waitKind: waitKind,
            statusSince: now.addingTimeInterval(-30), updatedAt: now)
    }

    private func project(_ sessions: [AgentSession],
                         relay: WatchRelayState = .live,
                         observed: Date? = nil) -> WatchDashboardState {
        WatchDashboardProjection.make(
            snapshot: Snapshot(sessions: sessions, serverTime: now),
            quotas: [], relay: relay, now: observed ?? now)
    }

    @Test("No-data is a placeholder, not a row of invented zeros")
    func noDataIsPlaceholder() {
        let state = WatchDashboardState.noData(observedAt: now)
        #expect(state.showsComplicationPlaceholder)
        #expect(state.counts.isEmpty)
        #expect(state.smartStackScore(now: now) == 0)
    }

    @Test("A live empty desk is zeros, not a placeholder")
    func emptyLiveShowsZeros() {
        let state = project([])
        #expect(!state.showsComplicationPlaceholder)
        #expect(state.counts == WatchSessionCounts())
        #expect(state.smartStackScore(now: now) == 0)
    }

    @Test("needsResponse raises the Smart Stack; working and done do not")
    func waitingRaisesSmartStack() {
        let waiting = project([
            session("a", .needsResponse, waitKind: .permission),
            session("b", .needsResponse, waitKind: .question),
            session("c", .working),
        ])
        #expect(waiting.counts.needsResponse == 2)
        #expect(waiting.smartStackScore(now: now) == 2)

        let calm = project([session("c", .working), session("d", .done)])
        #expect(calm.smartStackScore(now: now) == 0)
    }

    @Test("A stale waiting count does not keep the card at the top")
    func staleWaitingDoesNotFloat() {
        let aged = project(
            [session("a", .needsResponse, waitKind: .question)],
            observed: now.addingTimeInterval(-WatchDashboardState.staleAfter))
        #expect(aged.counts.needsResponse == 1)
        #expect(aged.isStale(now: now))
        #expect(aged.smartStackScore(now: now) == 0)
    }
}
