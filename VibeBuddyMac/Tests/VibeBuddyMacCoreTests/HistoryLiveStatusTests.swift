import Foundation
import XCTest
import VibeBuddyKit
@testable import VibeBuddyMacCore

final class HistoryLiveStatusTests: XCTestCase {
    func testGroupingCallerExclusionAndReadOnlyRequest() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func row(_ id: String, _ cwd: String) -> AgentSession {
            AgentSession(id: id, agent: .codex, project: "repo", status: .working,
                         terminalRef: TerminalRef(cwd: cwd), controlChannel: .appserver, statusSince: now, updatedAt: now)
        }
        let token = "isolated-test-bearer-do-not-show"
        let data = try JSONEncoder().encode(Snapshot(sessions: [row("self", "/checkout/a"), row("other", "/checkout/a"), row(token, "/checkout/b")], serverTime: now))
        let result = try await HistoryLiveStatus.call(arguments: ["exclude_session": "self"], environment: ["VIBEBUDDY_TOKEN": token, "VIBEBUDDY_PORT": "18789"], fetch: { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.absoluteString, "http://127.0.0.1:18789/snapshot")
            XCTAssertEqual(request.timeoutInterval, 2)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer " + token)
            return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        XCTAssertFalse(result.contains("- self |"))
        XCTAssertTrue(result.contains("## /checkout/a"))
        XCTAssertTrue(result.contains("## /checkout/b"))
        XCTAssertTrue(result.contains("Another agent is working in this checkout"))
        XCTAssertTrue(result.contains("controlChannel: appserver"))
        XCTAssertFalse(result.contains(token))
        let alone = HistoryLiveStatus.render(Snapshot(sessions: [row("self", "/checkout/a")], serverTime: now), project: "/checkout/a", excludeSession: "self")
        XCTAssertTrue(alone.contains("No other live sessions found."))
        var older = row("old", "/checkout/c")
        older.status = .done; older.updatedAt = now.addingTimeInterval(-7 * 86400)
        XCTAssertFalse(HistoryLiveStatus.render(Snapshot(sessions: [older], serverTime: now), project: nil, excludeSession: nil).contains("- old |"))
        let onlyA = HistoryLiveStatus.render(try JSONDecoder().decode(Snapshot.self, from: data), project: "/checkout/a", excludeSession: "self")
        XCTAssertTrue(onlyA.contains("- other |")); XCTAssertFalse(onlyA.contains("## /checkout/b"))
    }

    func testUnknownStatusAndMissingTokenNeverCreateState() async throws {
        let result = try await HistoryLiveStatus.call(arguments: [:], environment: ["VIBEBUDDY_TOKEN": "synthetic", "VIBEBUDDY_PORT": "1"])
        XCTAssertEqual(result, "live status unknown (daemon not reachable at 127.0.0.1:1)")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        XCTAssertNil(TokenStore(fileURL: root.appendingPathComponent("token")).load())
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        let request = try HistoryCLI.parse(["status", "--project", "/checkout/a", "--exclude-session", "self"])
        XCTAssertEqual(request.tool, "vibebuddy_live_status")
        XCTAssertEqual(request.arguments["exclude_session"] as? String, "self")
    }
}
