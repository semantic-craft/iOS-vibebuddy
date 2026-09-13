import Foundation
import XCTest
@testable import VibeBuddyMacCore

@MainActor
final class HistoryMCPTests: XCTestCase {
    private func fixture() async throws -> (URL, SessionHistoryRepository) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let claude = root.appendingPathComponent("claude"), codex = root.appendingPathComponent("codex")
        let source = codex.appendingPathComponent("sessions/one.jsonl")
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data((#"{"type":"session_meta","payload":{"id":"native","cwd":"/repo","source":"cli"}}"# + "\n" + #"{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"中文 context"}]}}"#).utf8).write(to: source)
        let directory = root.appendingPathComponent("history")
        let writer = SessionHistoryRepository(claudeHome: claude, codexHome: codex, cacheDirectory: directory)
        _ = try await writer.refresh()
        return (root, SessionHistoryRepository(claudeHome: claude, codexHome: codex, cacheDirectory: directory, readOnly: true))
    }
    private func request(_ server: HistoryMCPServer, _ method: String, _ params: [String: Any] = [:]) async throws -> [String: Any] {
        let data = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": "request", "method": method, "params": params])
        let response = try await server.response(to: data)
        return try JSONSerialization.jsonObject(with: XCTUnwrap(response)) as! [String: Any]
    }
    private func initialize(_ server: HistoryMCPServer, version: String = "2025-11-25") async throws -> [String: Any] {
        try await request(server, "initialize", ["protocolVersion": version, "capabilities": [:], "clientInfo": ["name": "test", "version": "1"]])
    }
    private func text(_ response: [String: Any]) throws -> String {
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        return try XCTUnwrap((result["content"] as? [[String: Any]])?.first?["text"] as? String)
    }

    func testLifecycleRegistrySnapshotAndNotifications() async throws {
        let (root, repository) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let server = HistoryMCPServer(executor: HistoryToolExecutor(repository: repository))
        let early = try await request(server, "tools/list")
        XCTAssertEqual((early["error"] as? [String: Any])?["code"] as? Int, -32602)
        let initialized = try await initialize(server, version: "future-version")
        XCTAssertEqual((initialized["result"] as? [String: Any])?["protocolVersion"] as? String, "2025-11-25")
        let notification = try await server.response(to: Data(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8))
        XCTAssertNil(notification)
        let listed = try await request(server, "tools/list")
        let tools = try XCTUnwrap((listed["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        let expected = Bundle.module.url(forResource: "history-mcp-tools", withExtension: "json", subdirectory: "Fixtures")!
        let actualData = try JSONSerialization.data(withJSONObject: tools, options: [.sortedKeys])
        let expectedData = try JSONSerialization.data(withJSONObject: JSONSerialization.jsonObject(with: Data(contentsOf: expected)), options: [.sortedKeys])
        XCTAssertEqual(actualData, expectedData)
        let names = tools.compactMap { $0["name"] as? String }
        XCTAssertEqual(Set(names), Set(HistoryCLI.commands.values))
        XCTAssertEqual(names.count, HistoryCLI.commands.count)
        let unknown = try await request(server, "write/anything")
        XCTAssertEqual((unknown["error"] as? [String: Any])?["code"] as? Int, -32601)
    }

    func testSharedExecutionParityErrorsEmptyResultsAndUnchangedStore() async throws {
        let (root, repository) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = root.appendingPathComponent("history")
        func bytes() throws -> [String: Data] {
            try Dictionary(uniqueKeysWithValues: FileManager.default.contentsOfDirectory(at: store, includingPropertiesForKeys: nil).map { ($0.lastPathComponent, try Data(contentsOf: $0)) })
        }
        let before = try bytes()
        let executor = HistoryToolExecutor(repository: repository)
        let server = HistoryMCPServer(executor: executor)
        _ = try await initialize(server)
        for (command, name) in HistoryCLI.commands {
            let parsed = try HistoryCLI.parse([command, "--limit", "5"])
            XCTAssertEqual(parsed.arguments["limit"] as? String, "5")
            let arguments = try HistoryTools.normalizeCLIArguments(name, arguments: parsed.arguments)
            let cli = try await executor.execute(name, arguments: arguments)
            let response = try await request(server, "tools/call", ["name": name, "arguments": ["limit": 5]])
            XCTAssertEqual(Data(HistoryCLI.output(cli).utf8), Data((try text(response) + "\n").utf8))
            let call = try HistoryCLI.parse(["call", name, #"{"limit":5}"#])
            let called = try await executor.execute(call.tool, arguments: call.arguments)
            XCTAssertEqual(called, cli)
        }
        let malformed = try await request(server, "tools/call", ["name": "vibebuddy_list_sessions", "arguments": ["limit": "5"]])
        XCTAssertEqual((malformed["error"] as? [String: Any])?["code"] as? Int, -32602)
        let failed = try await request(server, "tools/call", ["name": "vibebuddy_list_sessions", "arguments": ["since": "yesterday"]])
        XCTAssertNil(failed["error"])
        XCTAssertEqual((failed["result"] as? [String: Any])?["isError"] as? Bool, true)
        XCTAssertTrue(try text(failed).contains("Invalid since"))
        let empty = try await request(server, "tools/call", ["name": "vibebuddy_list_sessions", "arguments": ["since": "2999-01-01"]])
        XCTAssertEqual((empty["result"] as? [String: Any])?["isError"] as? Bool, false)
        XCTAssertTrue(try text(empty).contains("No sessions found"))
        XCTAssertEqual(try bytes(), before)
    }

    func testLongLivedConnectionSeesPublishedMetadata() async throws {
        let (root, repository) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let server = HistoryMCPServer(executor: HistoryToolExecutor(repository: repository))
        _ = try await initialize(server)
        let params: [String: Any] = ["name": "vibebuddy_list_sessions", "arguments": ["starred": true]]
        let first = try await request(server, "tools/call", params)
        XCTAssertTrue(try text(first).contains("No sessions found"))
        let writer = SessionHistoryRepository(claudeHome: root.appendingPathComponent("claude"), codexHome: root.appendingPathComponent("codex"), cacheDirectory: root.appendingPathComponent("history"))
        let snapshot = await writer.snapshot()
        let id = try XCTUnwrap(snapshot.sessions.first?.id)
        try await writer.setFavorite(sessionID: id, isFavorite: true)
        let second = try await request(server, "tools/call", params)
        XCTAssertTrue(try text(second).contains("codex:native"))
        let source = root.appendingPathComponent("codex/sessions/two.jsonl")
        try Data(#"{"type":"session_meta","payload":{"id":"second","cwd":"/repo","source":"cli"}}"#.utf8).write(to: source)
        _ = try await writer.refresh()
        let third = try await request(server, "tools/call", ["name": "vibebuddy_list_sessions"])
        XCTAssertTrue(try text(third).contains("codex:second"))
    }

    func testMalformedJSONAndShapeAreProtocolErrors() async throws {
        let (root, repository) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let server = HistoryMCPServer(executor: HistoryToolExecutor(repository: repository))
        let response = try await server.response(to: Data("{".utf8))
        let invalid = try JSONSerialization.jsonObject(with: XCTUnwrap(response)) as! [String: Any]
        XCTAssertEqual((invalid["error"] as? [String: Any])?["code"] as? Int, -32700)
        _ = try await initialize(server)
        let shape = try await request(server, "tools/call", ["name": "vibebuddy_list_sessions", "arguments": []])
        XCTAssertEqual((shape["error"] as? [String: Any])?["code"] as? Int, -32602)
        XCTAssertThrowsError(try HistoryCLI.parse(["call", "vibebuddy_list_sessions", "[]"]))
        for arguments: [String: Any] in [["limit": true], ["starred": 1], ["limit": 1.5], ["unexpected": "x"]] {
            XCTAssertThrowsError(try HistoryTools.validateArguments("vibebuddy_list_sessions", arguments: arguments))
        }
    }
}
