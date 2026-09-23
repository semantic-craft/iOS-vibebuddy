import Foundation
import XCTest
@testable import VibeBuddyMacCore

final class LegacyHistoryCleanupTests: XCTestCase {
    func testRemovesOnlyTheRetiredCacheAndItsTempDirs() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("legacy-history-" + UUID().uuidString)
        let temp = home.appendingPathComponent("tmp")
        defer { try? fm.removeItem(at: home) }
        let cache = home.appendingPathComponent("Library/Application Support/VibeBuddy/SessionHistory")
        let transcript = home.appendingPathComponent(".claude/projects/p/s.jsonl")
        let keptSupport = home.appendingPathComponent("Library/Application Support/VibeBuddy/recap-ledger.json")
        let staleTemp = temp.appendingPathComponent("vibebuddy-history-1234")
        let otherTemp = temp.appendingPathComponent("unrelated")
        for dir in [cache, transcript.deletingLastPathComponent(), staleTemp, otherTemp] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        try Data(repeating: 1, count: 64 * 1024).write(to: cache.appendingPathComponent("search.sqlite"))
        try Data("{}".utf8).write(to: cache.appendingPathComponent("index.json"))
        for file in [transcript, keptSupport] { try Data("keep".utf8).write(to: file) }

        let targets = LegacyHistoryCleanup.targets(home: home, temporaryDirectory: temp, environment: [:])
        XCTAssertEqual(Set(targets.map(\.lastPathComponent)), ["SessionHistory", "vibebuddy-history-1234"])
        let result = LegacyHistoryCleanup.run(targets)
        XCTAssertEqual(result.removed.count, 2)
        XCTAssertGreaterThanOrEqual(result.bytesFreed, 64 * 1024)
        XCTAssertFalse(fm.fileExists(atPath: cache.path))
        XCTAssertFalse(fm.fileExists(atPath: staleTemp.path))
        for kept in [transcript, keptSupport, otherTemp] { XCTAssertTrue(fm.fileExists(atPath: kept.path), kept.path) }

        // Nothing left to remove is a quiet no-op.
        XCTAssertEqual(LegacyHistoryCleanup.run(LegacyHistoryCleanup.targets(home: home, temporaryDirectory: temp, environment: [:])),
                       .init(removed: [], bytesFreed: 0))
    }

    func testE2ERunCleansOnlyItsOwnRoot() {
        let targets = LegacyHistoryCleanup.targets(home: URL(fileURLWithPath: "/Users/nobody"), temporaryDirectory: URL(fileURLWithPath: "/nonexistent"),
                                                   environment: ["VIBEBUDDY_E2E_ROOT": "/tmp/e2e-run"])
        XCTAssertEqual(targets.map(\.path), ["/tmp/e2e-run/history"])
    }
}
