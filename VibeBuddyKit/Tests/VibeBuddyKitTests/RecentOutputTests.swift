import Testing
import Foundation
@testable import VibeBuddyKit

@Suite("RecentOutput — wire contract")
struct RecentOutputTests {

    @Test("unavailable carries the reason and never invents entries")
    func unavailableHasNoEntries() {
        let output = RecentOutput.unavailable(sessionId: "s", reason: .noSource)
        #expect(output.sessionId == "s")
        #expect(output.entries.isEmpty)
        #expect(output.unavailable == .noSource)
        #expect(!output.truncated)
        #expect(output.statusLine == "No recent output source for this session.")
    }

    @Test("an available empty slice is distinct from unavailable")
    func emptyIsNotUnavailable() {
        let output = RecentOutput(sessionId: "s", source: .transcript, entries: [])
        #expect(output.unavailable == nil)
        #expect(output.statusLine == "No recent output yet.")
    }

    @Test("truncation is named without promising a full history")
    func truncatedStatus() {
        let output = RecentOutput(
            sessionId: "s", source: .rollout, truncated: true,
            entries: [RecentOutputEntry(role: "assistant", text: "done")])
        #expect(output.statusLine == "Bounded excerpt — not the full history.")
    }

    @Test("round-trips the fields the phone renders")
    func roundTrip() throws {
        let original = RecentOutput(
            sessionId: "thread-1",
            source: .appserver,
            updatedAt: Date(timeIntervalSince1970: 1_800_000_000),
            truncated: true,
            entries: [
                RecentOutputEntry(role: "user", text: "fix the test"),
                RecentOutputEntry(role: "assistant", text: "patched"),
            ])
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(RecentOutput.self, from: data)
        #expect(decoded == original)
    }
}
