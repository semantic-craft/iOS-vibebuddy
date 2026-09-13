import Foundation
import Testing
@testable import VibeBuddyKit

@Suite("Watch recap queue — Mark all is one send, retired only by the Mac")
struct WatchRecapQueueTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func entry(_ session: String, minutesAgo: Double, kind: RecapEntryKind = .completed, read: Bool = false) -> RecapEntry {
        RecapEntry(id: "mac/\(session)/\(kind)", kind: kind, sessionID: session,
                   completionID: kind == .completed ? session + "-round" : nil,
                   agent: .codex, project: "p", title: session, points: [],
                   endedAt: now.addingTimeInterval(-minutesAgo * 60), isRead: read)
    }

    private func state(recap: Recap?, relay: WatchRelayState = .live, source: String? = "mac", epoch: String? = "e1") -> WatchDashboardState {
        var state = WatchDashboardState(sourceID: source, recap: recap, relay: relay, observedAt: now)
        state.pairingEpoch = epoch
        return state
    }

    private var recap: Recap {
        Recap(horizon: nil, entries: [entry("a", minutesAgo: 1), entry("f", minutesAgo: 2, kind: .failed),
                                      entry("r", minutesAgo: 3, read: true), entry("b", minutesAgo: 4)])
    }

    @Test("Mark all names the newest round's end and every unread completed round; a second tap adds nothing")
    func markAllOnce() {
        var queue = WatchRecapQueue()
        let state = state(recap: recap)
        let request = queue.markAll(recap, state: state, attemptID: "t1")
        #expect(request?.horizon == now.addingTimeInterval(-60))
        #expect(request?.completions.map(\.sessionID) == ["a", "b"])       // not the failed one, not the read one
        #expect(request?.completions.allSatisfy { $0.sourceID == "mac" && $0.pairingEpoch == "e1" } == true)
        #expect(queue.markAll(recap, state: state, attemptID: "t2") == nil)
        #expect(queue.pending?.attemptID == "t1")
        #expect(queue.covers(recap, state: state))
    }

    @Test("without a Mac and a pairing, or with nothing to mark, there is nothing to send")
    func nothingToSend() {
        var queue = WatchRecapQueue()
        #expect(queue.markAll(recap, state: state(recap: recap, source: nil), attemptID: "t") == nil)
        #expect(queue.markAll(recap, state: state(recap: recap, epoch: nil), attemptID: "t") == nil)
        #expect(queue.markAll(Recap(), state: state(recap: Recap()), attemptID: "t") == nil)
        #expect(queue.isEmpty)
    }

    @Test("a failed delivery keeps the record; the Mac's acceptance stops retries; a snapshot horizon retires it")
    func receiptsAndSnapshots() {
        var queue = WatchRecapQueue()
        let current = state(recap: recap)
        queue.markAll(recap, state: current, attemptID: "t1")
        queue.received(.failed, attemptID: "t1")
        #expect(queue.pending != nil && queue.failures == 1)
        queue.received(.accepted, attemptID: "other")                        // not this attempt
        #expect(queue.pending != nil)
        queue.received(.accepted, attemptID: "t1")
        #expect(queue.pending == nil && queue.confirmed?.attemptID == "t1")
        #expect(queue.covers(recap, state: current))                         // still covers what is on screen
        // A snapshot that has not moved the horizon changes nothing.
        queue.reconcile(with: current)
        #expect(queue.confirmed != nil)
        // The Mac moved the horizon to the newest round: retired.
        var after = current
        after.recap = Recap(horizon: now.addingTimeInterval(-60), entries: [])
        queue.reconcile(with: after)
        #expect(queue.isEmpty)
    }

    @Test("a newer recap supersedes the queued request and keeps the rounds it named")
    func supersede() {
        var queue = WatchRecapQueue()
        queue.markAll(recap, state: state(recap: recap), attemptID: "t1")
        let newer = Recap(horizon: nil, entries: [entry("c", minutesAgo: 0.5)] + recap.entries)
        let request = queue.markAll(newer, state: state(recap: newer), attemptID: "t2")
        #expect(request?.attemptID == "t2")
        #expect(request?.horizon == now.addingTimeInterval(-30))
        #expect(Set(request?.completions.map(\.sessionID) ?? []) == ["a", "b", "c"])
    }

    @Test("another Mac or a new pairing drops the request; a disconnected relay keeps it")
    func identity() {
        var queue = WatchRecapQueue()
        queue.markAll(recap, state: state(recap: recap), attemptID: "t1")
        queue.reconcile(with: state(recap: recap, relay: .disconnected))
        #expect(queue.pending != nil)
        queue.received(.sourceMismatch, attemptID: "t1")
        #expect(queue.isEmpty)
        queue.markAll(recap, state: state(recap: recap), attemptID: "t2")
        queue.reconcile(with: state(recap: nil, epoch: "e2"))
        #expect(queue.isEmpty)
    }

    @Test("the queue rides the Watch's stored state, and a cache from before it decodes as empty")
    func persistence() throws {
        var queue = WatchRecapQueue()
        var live = state(recap: recap)
        live.relayRevision = 3
        queue.markAll(recap, state: live, attemptID: "t1")
        let record = WatchStoredState(state: live, queue: WatchCompletionQueue(), recapQueue: queue)
        let restored = try #require(WatchStoredState.decode(try JSONEncoder().encode(record)))
        #expect(restored.recapQueue == queue)
        #expect(restored.state.recap == recap)

        var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as! [String: Any]
        legacy.removeValue(forKey: "recapQueue")
        let old = try #require(WatchStoredState.decode(try JSONSerialization.data(withJSONObject: legacy)))
        #expect(old.recapQueue == nil)
    }

    @Test("Demo Mode resolves Mark all the way a Mac snapshot would")
    func demoResolution() {
        let before = WatchDemoScenario.normal.state(now: now)
        let after = before.resolvingRecap()
        #expect(after.recap?.entries.isEmpty == true)
        #expect(after.recap?.horizon == before.recap?.entries.first?.endedAt)
        #expect(after.presentation.completeUnread < before.presentation.completeUnread)
    }
}
