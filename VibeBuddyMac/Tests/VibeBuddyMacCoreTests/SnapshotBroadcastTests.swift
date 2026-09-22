import Foundation
import Testing
import VibeBuddyKit
@testable import VibeBuddyMacCore

@Suite("Snapshot broadcast coalescing")
struct SnapshotBroadcastTests {
    /// Five changes inside one window: one snapshot goes out at once, one
    /// trailing snapshot carries the final state; the three in between are
    /// never handed to the subscriber.
    @Test func burstsCollapseToLeadingAndTrailing() async throws {
        let store = SessionStore()
        let subscription = await store.subscribe()
        defer { Task { await store.unsubscribe(subscription.id) } }
        // Whatever `bufferingNewest(1)` lets through, the last frame the
        // subscriber sees must be the burst's final state.
        let collector = Task { () -> [[AgentKind]?] in
            var seen: [[AgentKind]?] = []
            for await snapshot in subscription.stream { seen.append(snapshot.dispatchAgents) }
            return seen
        }
        for agents in [[AgentKind.cursor], [.grok], [.claudeCode], [.codex], [.cursor]] {
            await store.setDispatchAgents(agents)
        }
        let afterBurst = await store.broadcastCount
        #expect(afterBurst == 1, "\(afterBurst)")
        // The trailing frame is due after one window; a loaded test host may
        // run it late, never early.
        #expect(await settles(to: 2))
        #expect(await store.snapshot(now: Date()).dispatchAgents == [.cursor])
        try await Task.sleep(for: .milliseconds(100))
        collector.cancel()
        let seen = await collector.value
        #expect(seen.last == [.cursor], "\(seen)")

        // Quiet again: the next change is immediate once more.
        try await Task.sleep(for: SessionStore.broadcastWindow * 2)
        await store.setDispatchAgents([.grok])
        let afterQuiet = await store.broadcastCount
        #expect(afterQuiet == 3, "\(afterQuiet)")

        func settles(to count: Int) async -> Bool {
            let deadline = ContinuousClock.now + .seconds(5)
            while ContinuousClock.now < deadline {
                if await store.broadcastCount == count { return true }
                try? await Task.sleep(for: .milliseconds(20))
            }
            return false
        }
    }
}
