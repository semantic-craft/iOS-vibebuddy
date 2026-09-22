import Foundation
import Testing
@testable import VibeBuddyMacCore

@Suite("History re-index throttle")
struct HistoryReindexThrottleTests {
    @Test func aChangingFileIsIndexedOncePerWindowAndNeverDropped() {
        var throttle = HistoryReindexThrottle(interval: 15)
        let t0 = Date(timeIntervalSince1970: 1_000)
        let first = throttle.split(["/a.jsonl", "/b.jsonl"], now: t0)
        #expect(first.due == ["/a.jsonl", "/b.jsonl"] && first.deferred.isEmpty)
        throttle.markIndexed(first.due, at: t0)

        // Reported again 0.3 s later: held, not lost.
        let again = throttle.split(["/a.jsonl"], now: t0.addingTimeInterval(0.3))
        #expect(again.due.isEmpty && again.deferred == ["/a.jsonl"])

        // A new file is due at once even while another is held.
        let mixed = throttle.split(["/a.jsonl", "/c.jsonl"], now: t0.addingTimeInterval(5))
        #expect(mixed.due == ["/c.jsonl"] && mixed.deferred == ["/a.jsonl"])

        // The window passes: the held file goes out.
        let later = throttle.split(["/a.jsonl"], now: t0.addingTimeInterval(15))
        #expect(later.due == ["/a.jsonl"])
    }

    @Test func retainForgetsFilesThatStoppedChanging() {
        var throttle = HistoryReindexThrottle(interval: 15)
        let t0 = Date(timeIntervalSince1970: 1_000)
        throttle.markIndexed(["/a.jsonl", "/b.jsonl"], at: t0)
        throttle.retain(["/a.jsonl"], now: t0.addingTimeInterval(60))
        // /b is gone from the table, so it is due immediately when it reappears;
        // /a was retained and is due too because its window has passed.
        let split = throttle.split(["/a.jsonl", "/b.jsonl"], now: t0.addingTimeInterval(60))
        #expect(split.due == ["/a.jsonl", "/b.jsonl"])
    }

    /// The stamp of a path that is not pending right now must survive while
    /// its window is open, or the next event for it would skip the throttle.
    @Test func retainKeepsAnInWindowStampForAPathNotCurrentlyPending() {
        var throttle = HistoryReindexThrottle(interval: 15)
        let t0 = Date(timeIntervalSince1970: 1_000)
        throttle.markIndexed(["/a.jsonl"], at: t0)
        throttle.retain([], now: t0.addingTimeInterval(1))
        let split = throttle.split(["/a.jsonl"], now: t0.addingTimeInterval(2))
        #expect(split.due.isEmpty && split.deferred == ["/a.jsonl"])
    }
}
