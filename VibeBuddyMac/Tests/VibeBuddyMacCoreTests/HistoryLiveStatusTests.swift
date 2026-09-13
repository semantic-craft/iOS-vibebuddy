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

    func testDesktopCheckoutSurvivesReducerAndSnapshotWithoutTerminalRef() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var source = CodexAppServerReducer()
        var reducer = SessionReducer()
        for (id, cwd) in [("desktop-a", "/clones/a/repo"), ("desktop-b", "/clones/b/repo")] {
            let thread: [String: Any] = ["id": id, "sessionId": id, "cwd": cwd, "source": "vscode",
                                        "status": ["type": "active", "activeFlags": []], "turns": []]
            for event in source.seed(thread: thread, receivedAt: now) { reducer.apply(event) }
        }
        let snapshot = try JSONDecoder().decode(Snapshot.self, from: JSONEncoder().encode(
            Snapshot(sessions: Array(reducer.sessions.values), serverTime: now)))
        XCTAssertEqual(snapshot.sessions.count, 2)
        XCTAssertTrue(snapshot.sessions.allSatisfy { $0.terminalRef == nil && $0.desktopThreadID == $0.id })
        let result = HistoryLiveStatus.render(snapshot, project: nil, excludeSession: nil)
        XCTAssertTrue(result.contains("## /clones/a/repo"))
        XCTAssertTrue(result.contains("## /clones/b/repo"))
        let filtered = HistoryLiveStatus.render(snapshot, project: "/clones/a/repo/", excludeSession: nil)
        XCTAssertTrue(filtered.contains("- desktop-a |")); XCTAssertFalse(filtered.contains("- desktop-b |"))
        let typo = HistoryLiveStatus.render(snapshot, project: "/clones/typo/repo", excludeSession: nil)
        XCTAssertTrue(typo.contains("project not found or ambiguous"))
        XCTAssertFalse(typo.contains("No other live sessions found."))

        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot.sessions[0])) as? [String: Any])
        legacy.removeValue(forKey: "checkoutPath")
        legacy.removeValue(forKey: "controlChannel")
        let oldSession = try JSONDecoder().decode(AgentSession.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertNil(oldSession.checkoutPath)
        XCTAssertTrue(HistoryLiveStatus.render(Snapshot(sessions: [oldSession], serverTime: now), project: nil, excludeSession: nil).contains("controlChannel: appserver"))
        reducer.apply(HookEvent(kind: .sessionMetadataChanged, sessionID: "desktop-a", agent: .codex,
                               cwd: "https://example.com/repo", timestamp: now))
        XCTAssertEqual(reducer.sessions["desktop-a"]?.checkoutPath, "/clones/a/repo")
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
