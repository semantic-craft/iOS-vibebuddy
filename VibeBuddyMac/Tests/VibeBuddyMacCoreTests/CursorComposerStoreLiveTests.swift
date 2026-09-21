import Foundation
import Testing
@testable import VibeBuddyMacCore

/// Times a read of a real Cursor `state.vscdb`. Opt in with
/// `VIBEBUDDY_CURSOR_DB_LIVE=1`; `VIBEBUDDY_CURSOR_DB` points at a copy of the
/// database (default: the signed-in user's own). The budget is generous on
/// purpose — the failure this guards against was a read of twenty seconds to
/// two minutes against a 1.4 GB store.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["VIBEBUDDY_CURSOR_DB_LIVE"] == "1"))
struct CursorComposerStoreLiveTests {
    @Test func aRealStoreReadsInUnderTwoSeconds() throws {
        let env = ProcessInfo.processInfo.environment
        var store = env["VIBEBUDDY_CURSOR_DB"].map { CursorComposerStore(database: URL(fileURLWithPath: $0)) }
            ?? CursorComposerStore()
        let started = Date()
        let composers = try #require(try store.refresh())
        let firstPass = Date().timeIntervalSince(started)
        let parsed = store.lastRefreshParsedDetails
        // A missing or empty database would pass the timing trivially.
        #expect(!composers.isEmpty)
        #expect(parsed > 0)
        // Unchanged file: no work at all.
        let again = Date()
        #expect(try store.refresh() == nil)
        let secondPass = Date().timeIntervalSince(again)
        print("cursor store: \(composers.count) conversations, \(parsed) decoded, first pass \(firstPass)s, unchanged pass \(secondPass)s")
        #expect(firstPass < 2)
        #expect(secondPass < 0.05)
    }
}
