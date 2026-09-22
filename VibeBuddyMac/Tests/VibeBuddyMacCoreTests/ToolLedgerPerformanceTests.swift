import Foundation
import XCTest
import VibeBuddyKit
@testable import VibeBuddyMacCore

/// Run with VIBEBUDDY_LEDGER_BENCHMARK=1 swift test --filter ToolLedgerPerformanceTests.
/// Fixture construction is outside the timed region; every run uses the same full ledger.
final class ToolLedgerPerformanceTests: XCTestCase {
    func testFullLedgerOperations() throws {
        guard ProcessInfo.processInfo.environment["VIBEBUDDY_LEDGER_BENCHMARK"] == "1" else {
            throw XCTSkip("Opt-in disk benchmark")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        var fixture: [String: [ToolCallRecord]] = [:]
        for session in 0..<250 {
            fixture["session-\(session)"] = (0..<50).map { index in
                ToolCallRecord(id: "tool-\(index)", tool: "Bash", command: "git status --short",
                    files: ["Sources/Example.swift"], result: .succeeded,
                    observedAt: now.addingTimeInterval(Double(session)), source: "hook", agent: .claudeCode)
            }
        }
        let data = try JSONEncoder().encode(fixture)
        XCTAssertLessThan(data.count, 8_000_000)
        let instant = now.addingTimeInterval(300)
        for operation in ["repeated-observe", "changed-observe", "unchanged-prune"] {
            for trial in 1...3 {
                let url = directory.appendingPathComponent("ledger.json")
                try data.write(to: url)
                var ledger = ToolLedger(url: url, now: instant)
                let clock = ContinuousClock()
                let elapsed = clock.measure {
                    for iteration in 0..<10 {
                        var record = fixture["session-249"]![49]
                        switch operation {
                        case "repeated-observe": ledger.observe(record, sessionID: "session-249", now: instant)
                        case "changed-observe":
                            record.command = "git status --short \(iteration)"
                            ledger.observe(record, sessionID: "session-249", now: instant)
                        default: ledger.prune(now: instant)
                        }
                    }
                }
                let components = elapsed.components
                let milliseconds = Double(components.seconds) * 1000 + Double(components.attoseconds) / 1e15
                print("LEDGER_BENCH operation=\(operation) trial=\(trial) operations=10 records=12500 bytes=\(data.count) milliseconds=\(milliseconds)")
                // Writes are one per window; flush the tail before comparing to disk.
                Thread.sleep(forTimeInterval: ToolLedger.writeInterval)
                ledger.prune(now: instant.addingTimeInterval(ToolLedger.writeInterval))
                XCTAssertEqual(ToolLedger(url: url, now: instant).sessions, ledger.sessions)
            }
        }
    }
}
