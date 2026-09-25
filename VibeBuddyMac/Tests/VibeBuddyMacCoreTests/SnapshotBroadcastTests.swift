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
        // The window is read on a clock only this test moves: the burst stays
        // inside it and the trailer waits for it, however slow the host.
        let clock = ManualClock()
        await store.setBroadcastClockForTesting(clock.broadcastClock)
        let subscription = await store.subscribe()
        // A second listener keeps deliveries counted after the first one leaves.
        let listener = await store.subscribe()
        defer { Task { await store.unsubscribe(listener.id) } }
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
        // Nothing trails before the window has passed.
        try await Task.sleep(for: .milliseconds(50))
        #expect(await store.broadcastCount == 1)
        clock.advance(by: SessionStore.broadcastWindow)
        try await eventually { await store.broadcastCount >= 2 }
        #expect(await store.broadcastCount == 2)
        #expect(await store.snapshot(now: Date()).dispatchAgents == [.cursor])
        // Finishing the stream still hands over the buffered frame, then ends
        // the collector: no wait on the wall clock.
        await store.unsubscribe(subscription.id)
        let seen = await collector.value
        #expect(seen.last == [.cursor], "\(seen)")

        // Quiet again: the next change is immediate once more.
        clock.advance(by: SessionStore.broadcastWindow * 2)
        await store.setDispatchAgents([.grok])
        let afterQuiet = await store.broadcastCount
        #expect(afterQuiet == 3, "\(afterQuiet)")
    }

    /// Polls until `condition` holds. The bound is liveness only.
    private func eventually(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(30)
        while ContinuousClock.now < deadline, !(await condition()) {
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

/// A clock that moves only when told; sleepers wake when it passes their instant.
private final class ManualClock: @unchecked Sendable {
    private let lock = NSLock()
    private let origin = ContinuousClock.now
    private var offset: Duration = .zero
    private var sleepers: [(ContinuousClock.Instant, CheckedContinuation<Void, Never>)] = []

    var now: ContinuousClock.Instant { lock.withLock { origin + offset } }

    func advance(by duration: Duration) {
        let due = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            offset += duration
            let now = origin + offset
            let ready = sleepers.filter { $0.0 <= now }.map(\.1)
            sleepers.removeAll { $0.0 <= now }
            return ready
        }
        due.forEach { $0.resume() }
    }

    func sleep(until instant: ContinuousClock.Instant) async {
        await withCheckedContinuation { continuation in
            let ready = lock.withLock { () -> Bool in
                if instant <= origin + offset { return true }
                sleepers.append((instant, continuation))
                return false
            }
            if ready { continuation.resume() }
        }
    }

    var broadcastClock: SessionStore.BroadcastClock {
        SessionStore.BroadcastClock(now: { self.now }, sleep: { await self.sleep(until: $0) })
    }
}
