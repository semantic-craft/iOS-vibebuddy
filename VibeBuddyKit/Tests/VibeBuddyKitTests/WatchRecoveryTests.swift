import Foundation
import Testing
@testable import VibeBuddyKit

@Suite("Watch recovery and source isolation")
struct WatchRecoveryTests {
    func state(_ source: String, epoch: String, revision: UInt64, observed: Double) -> WatchDashboardState {
        WatchDashboardState(sourceID: source, pairingEpoch: epoch, relayRevision: revision,
                            relay: .live, observedAt: Date(timeIntervalSince1970: observed))
    }

    @Test("phone Demo cannot replace live state or advance its authority revision")
    func demoIsolation() {
        let live = state("a", epoch: "p1", revision: 10, observed: 2000)
        var inbox = WatchStateInbox(state: live)
        var demo = live
        demo.isDemo = true; demo.relayRevision = 100
        let acceptedDemo = inbox.accept(WatchStateInbox.encode(demo))
        #expect(!acceptedDemo)
        #expect(inbox.state == live)
        var next = live; next.relayRevision = 11
        let acceptedLive = inbox.accept(WatchStateInbox.encode(next))
        #expect(acceptedLive)
    }

    @Test("Phone order survives restart and unrelated Mac clocks")
    func sourceOrder() throws {
        var inbox = WatchStateInbox()
        let a = state("a", epoch: "p1", revision: 10, observed: 2000)
        let b = state("b", epoch: "p2", revision: 11, observed: 1000)
        let accepted1 = inbox.accept(WatchStateInbox.encode(a))
        #expect(accepted1)
        let accepted2 = inbox.accept(WatchStateInbox.encode(b))
        #expect(accepted2)
        let saved = WatchStoredState(state: b, queue: WatchCompletionQueue())
        let recovered = try #require(WatchStoredState.decode(JSONEncoder().encode(saved)))
        inbox = WatchStateInbox(state: recovered.state)
        let accepted3 = inbox.accept(WatchStateInbox.encode(a))
        #expect(!accepted3)
        var reset = a; reset.relayRevision = 0
        let accepted4 = inbox.accept(WatchStateInbox.encode(reset))
        #expect(!accepted4)
        #expect(inbox.state?.sourceID == "b")
        #expect(inbox.state?.observedAt == Date(timeIntervalSince1970: 1000))
    }

    @Test("Same pairing phone cold launch preserves cached task while a changed pairing clears it")
    func coldPhone() {
        let a = state("a", epoch: "p1", revision: 10, observed: 2000)
        var inbox = WatchStateInbox(state: a)
        var starting = WatchDashboardState(pairingEpoch: "p1", relayRevision: 11,
            relay: .disconnected, observedAt: Date())
        let accepted = inbox.accept(WatchStateInbox.encode(starting))
        #expect(accepted)
        #expect(inbox.state?.sourceID == "a")
        #expect(inbox.state?.observedAt == a.observedAt)
        #expect(inbox.state?.relay == .disconnected)
        starting.pairingEpoch = "p2"; starting.relayRevision = 12
        let cleared = inbox.accept(WatchStateInbox.encode(starting))
        #expect(cleared)
        #expect(inbox.state?.sourceID == nil)
    }

    @Test("Atomic document preserves age, queue and safe detail; corruption has no partial recovery")
    func sharedRecovery() throws {
        var live = state("a", epoch: "p1", revision: 1, observed: 1000)
        live.alerts = [WatchAlert(sessionId: "s", agent: .claudeCode, project: "Project",
            waitKind: .permission, request: "private command", approvalId: "approval",
            waitingSince: live.observedAt)]
        let record = WatchStoredState(state: live, queue: WatchCompletionQueue())
        let bytes = try JSONEncoder().encode(record)
        let restored = try #require(WatchStoredState.decode(bytes))
        #expect(restored.state.alerts.first?.request == nil)
        #expect(restored.state.alerts.first?.approvalId == nil)
        #expect(restored.state.isStale(now: live.observedAt.addingTimeInterval(WatchDashboardState.staleAfter)))
        #expect(restored.state.observedAt == restored.complication.observedAt)
        #expect(WatchStoredState.decode(bytes.dropLast()) == nil)
        var inbox = WatchStateInbox(state: restored.state)
        let accepted5 = inbox.accept(WatchStateInbox.encode(live))
        #expect(accepted5)
        #expect(inbox.state?.alerts.first?.approvalId == "approval")
    }

    @Test("New pairing invalidates queued reads before new authority is connected")
    func pairingQueue() {
        let fixture = WatchCompletionTests()
        var queue = WatchCompletionQueue()
        queue.viewed(fixture.link, state: fixture.state())
        var disconnected = fixture.state(); disconnected.relay = .disconnected
        queue.reconcile(with: disconnected)
        #expect(queue.links.count == 1)
        disconnected.pairingEpoch = "new-pairing"
        disconnected.sourceID = nil
        queue.reconcile(with: disconnected)
        #expect(queue.links.isEmpty)
    }
}
