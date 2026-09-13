import Foundation
import XCTest
@testable import VibeBuddyMacCore

final class HistoryConnectionSetupTests: XCTestCase {
    func testClientSnippetsPreserveExecutablePathAndAreSharedWithSetup() throws {
        let path = "/A folder/owner's \"app\"\\copy\n/vibebuddy-mcp"
        let setup = HistoryConnectionSetup(executablePath: path)
        let printed = setup.instructions(indexAvailable: false)
        XCTAssertTrue(printed.contains("Note:"))
        for client in HistoryConnectionSetup.Client.allCases {
            XCTAssertTrue(printed.contains(setup.configuration(for: client)))
        }
        let cursor = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(setup.configuration(for: .cursor).utf8)) as? [String: Any])
        let servers = try XCTUnwrap(cursor["mcpServers"] as? [String: [String: Any]])
        XCTAssertEqual(servers["vibebuddy"]?["command"] as? String, path)
        XCTAssertEqual(servers["vibebuddy"]?["args"] as? [String], [])
        XCTAssertTrue(setup.configuration(for: .claude).contains("--scope project --transport stdio"))
        XCTAssertTrue(setup.configuration(for: .claude).contains("'\"'\"'"))
        XCTAssertFalse(setup.configuration(for: .codex).contains("\\/"))
        XCTAssertFalse(setup.instructions(indexAvailable: true).contains("Note:"))
        XCTAssertTrue(printed.contains(setup.agentRule))
    }
}
