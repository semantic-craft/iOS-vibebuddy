import XCTest
import VibeBuddyKit
@testable import VibeBuddyMacCore

final class ToolLedgerTests: XCTestCase {
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
