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
