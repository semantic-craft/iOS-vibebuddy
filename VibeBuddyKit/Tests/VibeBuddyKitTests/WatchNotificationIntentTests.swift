import Foundation
import Testing
@testable import VibeBuddyKit

struct WatchNotificationIntentTests {
    @Test func tapSurvivesRestartButNotPairingChangeOrExpiry() throws {
        let time = Date(timeIntervalSince1970: 1000)
        let link = WatchTaskLink(sourceID: "mac", pairingEpoch: "pair", sessionID: "task", completionID: "round")
        let data = try JSONEncoder().encode(WatchNotificationIntent(link: link, createdAt: time))
        let restored = try JSONDecoder().decode(WatchNotificationIntent.self, from: data)
        var state = WatchDashboardState(sourceID: "mac", pairingEpoch: "pair", relay: .live, observedAt: time)
        #expect(restored.target(in: state, now: time.addingTimeInterval(96)) == link)
        #expect(restored.target(in: state, now: time.addingTimeInterval(301)) == nil)
        state.pairingEpoch = "other"
        #expect(restored.target(in: state, now: time) == nil)
        state.pairingEpoch = "pair"; state.sourceID = "other"
        #expect(restored.target(in: state, now: time) == nil)
    }
}
