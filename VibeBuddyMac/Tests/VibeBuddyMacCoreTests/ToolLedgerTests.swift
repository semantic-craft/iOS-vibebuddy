import XCTest
import VibeBuddyKit
@testable import VibeBuddyMacCore

final class ToolLedgerTests: XCTestCase {
    /// An agent mid-task observes several tool calls a second; the sidecar is
    /// written once per window, the change inside it goes out with the next
    /// prune or observation after the window, and nothing is lost.
    func testWritesAtMostOncePerWindowAndFlushesAfterwards() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("ledger.json")
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        var ledger = ToolLedger(url: url, now: t0)
        for i in 0..<5 {
            let record = ToolCallRecord(id: "t\(i)", tool: "Bash", result: .succeeded,
                                        observedAt: t0.addingTimeInterval(Double(i) * 0.1), source: "hook")
            ledger.observe(record, sessionID: "s", now: t0.addingTimeInterval(Double(i) * 0.1))
        }
        XCTAssertEqual(ledger.writeCount, 1)
        XCTAssertEqual(ToolLedger(url: url, now: t0).sessions["s"]?.count, 1)  // only the first made it to disk so far

        XCTAssertTrue(ledger.needsTrailingWrite)
        // Inside the window a prune writes nothing, whatever `now` says — the
        // anchor is monotonic, so an older event timestamp cannot reopen it.
        ledger.prune(now: t0.addingTimeInterval(-60))
        XCTAssertEqual(ledger.writeCount, 1)

        // Once the window has passed, the next prune writes the rest.
        Thread.sleep(forTimeInterval: ToolLedger.writeInterval)
        ledger.prune(now: t0.addingTimeInterval(1))
        XCTAssertEqual(ledger.writeCount, 2)
        XCTAssertFalse(ledger.needsTrailingWrite)
        XCTAssertEqual(ToolLedger(url: url, now: t0).sessions["s"]?.count, 5)

        // Nothing pending: a prune writes nothing.
        ledger.prune(now: t0.addingTimeInterval(2))
        XCTAssertEqual(ledger.writeCount, 2)
    }

    func testRepeatedObservationRetriesFailedPersistence() throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: parent) }
        try Data("directory blocked".utf8).write(to: parent)
        let url = parent.appendingPathComponent("ledger.json")
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let record = ToolCallRecord(id: "t", tool: "Bash", result: .succeeded, observedAt: now, source: "hook")
        var ledger = ToolLedger(url: url, now: now)
        ledger.observe(record, sessionID: "s", now: now)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        try FileManager.default.removeItem(at: parent)
        ledger.observe(record, sessionID: "s", now: now)
        XCTAssertEqual(ToolLedger(url: url, now: now).sessions, ledger.sessions)
    }

    func testDuplicateObservationDoesNotRewriteButStillPrunesExpiredRecords() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: url) }
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let current = ToolCallRecord(id: "current", tool: "Bash", command: "true", result: .succeeded,
                                    observedAt: now, source: "hook")
        var ledger = ToolLedger(url: url, now: now)
        ledger.observe(current, sessionID: "s", now: now)
        let marker = now.addingTimeInterval(-1000)
        try FileManager.default.setAttributes([.modificationDate: marker], ofItemAtPath: url.path)
        ledger.observe(current, sessionID: "s", now: now)
        ledger.prune(now: now)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual(attributes[.modificationDate] as? Date, marker)
        ledger.observe(current, sessionID: "s", now: now.addingTimeInterval(8 * 86400))
        XCTAssertTrue(ledger.sessions.isEmpty)
        XCTAssertTrue(ToolLedger(url: url, now: now.addingTimeInterval(8 * 86400)).sessions.isEmpty)
    }

    func testByteLimitEvictsOldestSessionAndRemainsImmediatelyReloadable() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: url) }
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let paths = (0..<50).map { String(repeating: "x", count: 990) + String($0) }
        func record(_ index: Int, session: Int) -> ToolCallRecord {
            ToolCallRecord(id: "\(index)", tool: "Bash", command: String(repeating: "x", count: 2000),
                files: paths, result: .succeeded, observedAt: now.addingTimeInterval(Double(session)), source: "hook")
        }
        let fixture = Dictionary(uniqueKeysWithValues: (0..<4).map { session in
            ("s\(session)", (0..<35).map { record($0, session: session) })
        })
        let initial = try JSONEncoder().encode(fixture)
        XCTAssertLessThan(initial.count, 8_000_000)
        try initial.write(to: url)
        var ledger = ToolLedger(url: url, now: now)
        for index in 35..<50 { ledger.observe(record(index, session: 3), sessionID: "s3", now: now) }
        // Writes are one per window; the next snapshot pass after it flushes
        // the rest, and the cap is applied on that write.
        Thread.sleep(forTimeInterval: ToolLedger.writeInterval)
        ledger.prune(now: now)
        XCTAssertNil(ledger.sessions["s0"])
        XCTAssertEqual(ledger.sessions["s3"]?.count, 50)
        XCTAssertLessThanOrEqual(try Data(contentsOf: url).count, 8_000_000)
        XCTAssertEqual(ToolLedger(url: url, now: now).sessions, ledger.sessions)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: url.path))[.posixPermissions] as? Int, 0o600)
    }

    func testIntentResultLinkAndRepeatedEditsUseRetainedScope() {
        let now = Date(timeIntervalSince1970: 1000)
        var ledger = ToolLedger(url: nil, now: now)
        for index in 0..<2 {
            let intent = ToolCallRecord(id: "edit-\(index)", tool: "Edit", files: ["file.swift"],
                                       linesAdded: 2, linesRemoved: 1, observedAt: now, source: "hook")
            ledger.observe(intent, sessionID: "s", now: now)
            var result = intent; result.result = .succeeded
            ledger.observe(result, sessionID: "s", now: now)
            ledger.observe(intent, sessionID: "s", now: now)
        }
        for index in 0..<5 {
            ledger.observe(.init(id: "command-\(index)", tool: "Bash", command: "true",
                                 result: .succeeded, observedAt: now, source: "hook"), sessionID: "s", now: now)
        }
        ledger.observe(.init(id: "read", tool: "Read", files: ["untouched.swift"], result: .succeeded,
                             observedAt: now, source: "hook"), sessionID: "s", now: now)
        let failure = HookEvent(kind: .postToolUse, sessionID: "s", toolName: "Bash", toolError: true, timestamp: now)
        let rawFailure = Data(#"{"tool_use_id":"failure","tool_input":{"command":"false"},"error":"Exit code 1"}"#.utf8)
        if let record = ToolLedger.hook(rawFailure, event: failure) { ledger.observe(record, sessionID: "s", now: now) }
        let session = ledger.applying(to: AgentSession(id: "s", agent: .claudeCode, project: "test",
                                                      status: .working, statusSince: now, updatedAt: now))
        XCTAssertEqual(session.ledger?.count, 9)
        XCTAssertEqual(session.changedFiles, ["file.swift"])
        XCTAssertEqual(session.commandsRun, 6)
        XCTAssertEqual(session.linesAdded, 4)
        XCTAssertEqual(session.linesRemoved, 2)
    }

    func testRetentionAndMissingResultDoNotInventSuccess() {
        let now = Date(timeIntervalSince1970: 1000)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tool-ledger-test-" + UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: url) }
        var ledger = ToolLedger(url: url, now: now)
        for index in 0..<55 {
            ledger.observe(.init(id: "\(index)", tool: "Bash", command: "true", observedAt: now,
                                 source: "transcript"), sessionID: "s", now: now)
        }
        let session = ledger.applying(to: AgentSession(id: "s", agent: .cursor, project: "test",
                                                      status: .working, statusSince: now, updatedAt: now))
        XCTAssertEqual(ledger.sessions["s"]?.count, 50)
        XCTAssertEqual(session.ledger?.count, 20)
        XCTAssertEqual(session.commandsRun, 0)
        XCTAssertTrue(session.ledger?.allSatisfy { $0.result == .unconfirmed } == true)
        ledger.prune(now: now.addingTimeInterval(8 * 86400))
        XCTAssertTrue(ledger.sessions.isEmpty)
        let persisted = try? JSONDecoder().decode([String: [ToolCallRecord]].self, from: Data(contentsOf: url))
        XCTAssertTrue(persisted?.isEmpty == true)
    }
}
