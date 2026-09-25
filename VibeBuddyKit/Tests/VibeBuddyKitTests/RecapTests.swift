import Testing
import Foundation
@testable import VibeBuddyKit

@Suite("Recap — window rule and wire shape")
struct RecapTests {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func entry(_ id: String, minutesAgo: Double, kind: RecapEntryKind = .completed,
                       read: Bool = false) -> RecapEntry {
        RecapEntry(id: id, kind: kind, sessionID: "s-" + id,
                   completionID: kind == .completed ? "c-" + id : nil,
                   agent: .claudeCode, project: "vibebuddy", title: "Task " + id,
                   points: ["Did the thing"], endedAt: now.addingTimeInterval(-minutesAgo * 60), isRead: read)
    }

    @Test("without a horizon the window is the last 24 hours, newest first")
    func windowWithoutHorizon() {
        let recap = Recap.compose(entries: [
            entry("old", minutesAgo: 25 * 60),
            entry("b", minutesAgo: 90),
            entry("a", minutesAgo: 10),
            entry("edge", minutesAgo: 24 * 60),   // exactly 24h: not after the floor
        ], horizon: nil, now: now)
        #expect(recap.horizon == nil)
        #expect(recap.entries.map(\.id) == ["a", "b"])
    }

    @Test("a horizon inside the day narrows the window; one before it does not widen it")
    func horizonNarrowsOnly() {
        let entries = [entry("a", minutesAgo: 10), entry("b", minutesAgo: 90), entry("c", minutesAgo: 6 * 60)]
        let narrowed = Recap.compose(entries: entries, horizon: now.addingTimeInterval(-60 * 60), now: now)
        #expect(narrowed.entries.map(\.id) == ["a"])
        let wide = Recap.compose(entries: entries, horizon: now.addingTimeInterval(-3 * 24 * 60 * 60), now: now)
        #expect(wide.entries.map(\.id) == ["a", "b", "c"])
    }

    @Test("an entry that ended exactly at the horizon is already read; later ones stay")
    func horizonIsExclusive() {
        let horizon = now.addingTimeInterval(-30 * 60)
        let recap = Recap.compose(entries: [entry("at", minutesAgo: 30), entry("after", minutesAgo: 29)],
                                  horizon: horizon, now: now)
        #expect(recap.entries.map(\.id) == ["after"])
    }

    @Test("at most twelve entries survive, the newest ones")
    func capped() {
        let entries = (0..<20).map { entry("e\($0)", minutesAgo: Double($0) * 5 + 1) }
        let recap = Recap.compose(entries: entries, horizon: nil, now: now)
        #expect(recap.entries.count == Recap.maxEntries)
        #expect(recap.entries.first?.id == "e0")
        #expect(recap.entries.last?.id == "e11")
    }

    @Test("counts: failed rounds are never read; completed ones can be")
    func counts() {
        let recap = Recap.compose(entries: [
            entry("f", minutesAgo: 5, kind: .failed),
            entry("r", minutesAgo: 6, read: true),
            entry("u", minutesAgo: 7),
        ], horizon: nil, now: now)
        #expect(recap.failedCount == 1)
        #expect(recap.unreadCount == 2)
    }

    @Test("title and points are bounded on construction")
    func bounds() {
        let long = String(repeating: "x", count: 500)
        let entry = RecapEntry(id: "i", kind: .completed, sessionID: "s", agent: .codex, project: "p",
                               title: long, points: [long, long, long, long], endedAt: now)
        #expect(entry.title.count == RecapEntry.titleLimit)
        #expect(entry.points.count == RecapEntry.pointsLimit)
        #expect(entry.points.allSatisfy { $0.count == RecapEntry.pointLimit })
    }

    @Test("identities: a completed round shares the notice id; a failed round is keyed by its moment")
    func identities() {
        #expect(RecapEntry.completedID(sourceID: "mac", sessionID: "s", completionID: "c") == "mac/s/c")
        let failed = RecapEntry.failedID(sourceID: "mac", sessionID: "s", statusSince: now)
        #expect(failed == "mac/s/failed/1800000000000")
        #expect(RecapEntry.failedID(sourceID: "mac", sessionID: "s", statusSince: now.addingTimeInterval(0.25)) != failed)
    }

    @Test("a snapshot without recap decodes; with recap it round-trips")
    func wireCompatibility() throws {
        let legacySnapshot = Data(#"{"sessions":[],"serverTime":0}"#.utf8)
        let snapshot = try JSONDecoder().decode(Snapshot.self, from: legacySnapshot)
        #expect(snapshot.recap == nil)

        let recap = Recap(horizon: now, entries: [entry("a", minutesAgo: 1, kind: .failed)])
        var full = Snapshot(sessions: [], serverTime: now)
        full.recap = recap
        let back = try JSONDecoder().decode(Snapshot.self, from: JSONEncoder().encode(full))
        #expect(back.recap == recap)
    }
}
