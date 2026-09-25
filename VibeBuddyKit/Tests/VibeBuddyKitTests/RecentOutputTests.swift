import Testing
import Foundation
@testable import VibeBuddyKit

@Suite("RecentOutput — wire contract")
struct RecentOutputTests {

    @Test("an available empty slice is distinct from unavailable")
    func emptyIsNotUnavailable() {
        let output = RecentOutput(sessionId: "s", source: .transcript, entries: [])
        #expect(output.unavailable == nil)
        #expect(output.statusLine == "No recent output yet.")
    }
}
