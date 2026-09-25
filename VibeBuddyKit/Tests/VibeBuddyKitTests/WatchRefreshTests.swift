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
        func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }
        var policy = WatchActivationRefreshPolicy()
        let first = UUID(), second = UUID()
        let started = policy.begin(first, now: at(0))
        #expect(started)
        let whileInFlight = policy.begin(UUID(), now: at(20))
        #expect(!whileInFlight)
        let stranger = policy.finish(UUID(), succeeded: true)
        #expect(!stranger)
        let finished = policy.finish(first, succeeded: true)
        #expect(finished)
        let tooSoonAfterGood = policy.begin(UUID(), now: at(14))
        #expect(!tooSoonAfterGood)
        #expect(policy.retryDelay(now: at(14)) == nil)
        let paced = policy.begin(second, now: at(15))
        #expect(paced)
        _ = policy.finish(second, succeeded: false)
        #expect(policy.retryDelay(now: at(17)) == 1)
        let tooSoonAfterFailure = policy.begin(UUID(), now: at(17))
        #expect(!tooSoonAfterFailure)
        let retried = policy.begin(UUID(), now: at(18))
        #expect(retried)
    }
}
