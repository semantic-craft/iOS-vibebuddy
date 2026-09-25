import Foundation
import Testing
@testable import VibeBuddyKit

struct WatchRefreshTests {
    @Test func aReplyFromAnotherAttemptOrPairingCannotRefreshThisPage() throws {
        let request = WatchRefreshRequest(sourceID: "mac", pairingEpoch: "epoch")
        var state = WatchDashboardState(sourceID: "mac", pairingEpoch: "epoch", relay: .live, observedAt: .now)
        let reply = WatchRefreshReply(id: request.id, state: state)
        let restored = try JSONDecoder().decode(WatchRefreshReply.self, from: JSONEncoder().encode(reply))
        #expect(restored.snapshot(for: request) != nil)
        #expect(restored.snapshot(for: WatchRefreshRequest(sourceID: "mac", pairingEpoch: "epoch")) == nil)
        state.pairingEpoch = "new-epoch"
        #expect(WatchRefreshReply(id: request.id, state: state).snapshot(for: request) == nil)
        #expect(WatchRefreshReply(id: request.id, state: nil).snapshot(for: request) == nil)
    }
}

struct WatchActivationRefreshPolicyTests {
    /// WR-12: opening the app asks the iPhone for a snapshot, one at a time and
    /// paced, and a failed ask may be retried sooner than a good one repeats.
    @Test func activationRefreshIsOneAtATimeAndPaced() {
        let t0 = Date(timeIntervalSinceReferenceDate: 0)
        var policy = WatchActivationRefreshPolicy()
        func begin(after seconds: TimeInterval, _ id: UUID = UUID()) -> Bool {
            policy.begin(id, now: t0.addingTimeInterval(seconds))
        }
        func finish(_ id: UUID, _ succeeded: Bool) -> Bool { policy.finish(id, succeeded: succeeded) }
        let first = UUID(), second = UUID()
        let steps = [
            begin(after: 0, first),
            !begin(after: 20),          // one in flight
            !finish(UUID(), true),      // a reply to another attempt
            finish(first, true),
            !begin(after: 14),          // paced after a good one
            begin(after: 15, second),
            finish(second, false),
            !begin(after: 17),
            begin(after: 18),           // a failed one retries sooner
        ]
        #expect(steps == Array(repeating: true, count: steps.count))
    }
}
