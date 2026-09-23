import Foundation
import XCTest
@testable import VibeBuddyMacCore

@MainActor
final class HistoryMCPTests: XCTestCase {
    private func fixture() async throws -> (URL, SessionTranscriptReader) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let claude = root.appendingPathComponent("claude"), codex = root.appendingPathComponent("codex")
        let source = codex.appendingPathComponent("sessions/native.jsonl")
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data((#"{"type":"session_meta","payload":{"id":"native","cwd":"/repo","source":"cli"}}"# + "\n" + #"{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"中文 context"}]}}"#).utf8).write(to: source)
        return (root, SessionTranscriptReader(claudeHome: claude, codexHome: codex, cursorHome: root.appendingPathComponent("cursor")))
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
        let (root, reader) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let server = HistoryMCPServer(executor: HistoryToolExecutor(reader: reader, environment: ["VIBEBUDDY_PORT": "0"]))
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
        let (root, reader) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = root.appendingPathComponent("codex/sessions")
        // The daemon's ledgers, as `facts` reads them: every file must be byte-identical afterwards.
        let facts = root.appendingPathComponent("facts")
        try FileManager.default.createDirectory(at: facts, withIntermediateDirectories: true)
        for (name, body) in ["lifecycle-journal.json": #"{"schemaVersion":1,"entries":[]}"#, "tool-ledger.json": "{}",
                             "recent-directories.json": #"{"directories":{},"sessions":{}}"#, "continuations.json": "[]"] {
            try Data(body.utf8).write(to: facts.appendingPathComponent(name))
        }
        func bytes() throws -> [String: Data] {
            try Dictionary(uniqueKeysWithValues: ([store, facts].flatMap { dir in
                try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil).map { (dir.lastPathComponent + "/" + $0.lastPathComponent, try Data(contentsOf: $0)) }
            }))
        }
        let before = try bytes()
        XCTAssertEqual(before.keys.filter { $0.hasPrefix("facts/") }.count, 4)
        let executor = HistoryToolExecutor(reader: reader, environment: ["VIBEBUDDY_PORT": "0", "VIBEBUDDY_FACTS_DIRECTORY": facts.path])
        let server = HistoryMCPServer(executor: executor)
        _ = try await initialize(server)
        let requests: [(String, [String])] = [
            ("show", ["codex:native"]), ("status", []),
            ("facts", ["codex:native", "--commands", "3"])
        ]
        for (command, flags) in requests {
            let parsed = try HistoryCLI.parse([command] + flags)
            let arguments = try HistoryTools.normalizeCLIArguments(parsed.tool, arguments: parsed.arguments)
            let cli = try await executor.execute(parsed.tool, arguments: arguments)
            let response = try await request(server, "tools/call", ["name": parsed.tool, "arguments": arguments])
            XCTAssertEqual(Data(HistoryCLI.output(cli).utf8), Data((try text(response) + "\n").utf8))
            let json = String(decoding: try JSONSerialization.data(withJSONObject: arguments), as: UTF8.self)
            let call = try HistoryCLI.parse(["call", parsed.tool, json])
            let called = try await executor.execute(call.tool, arguments: call.arguments)
            XCTAssertEqual(called, cli)
        }
        let malformed = try await request(server, "tools/call", ["name": "vibebuddy_get_session", "arguments": ["key": "codex:native", "max_messages": "5"]])
        XCTAssertEqual((malformed["error"] as? [String: Any])?["code"] as? Int, -32602)
        for removed in ["vibebuddy_list_sessions", "vibebuddy_search", "vibebuddy_get_summary"] {
            let response = try await request(server, "tools/call", ["name": removed, "arguments": [:]])
            XCTAssertEqual((response["error"] as? [String: Any])?["code"] as? Int, -32602, removed)
        }
        for command in ["sessions", "projects", "search", "summary", "index"] {
            XCTAssertThrowsError(try HistoryCLI.parse([command, "x"]), command)
        }
        XCTAssertEqual(try bytes(), before)
    }

    func testGetSessionWireParityAndBadKeyErrorsWithoutAnyCache() async throws {
        let (root, reader) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let executor = HistoryToolExecutor(reader: reader, environment: ["VIBEBUDDY_PORT": "0"])
        let server = HistoryMCPServer(executor: executor)
        _ = try await initialize(server)
        for key in ["codex:native", "vibebuddy://session/codex:native#1"] {
            let response = try await request(server, "tools/call", ["name": "vibebuddy_get_session", "arguments": ["key": key, "max_messages": 2]])
            let parsed = try HistoryCLI.parse(["show", key, "--max-messages", "2"])
            let arguments = try HistoryTools.normalizeCLIArguments(parsed.tool, arguments: parsed.arguments)
            let cli = try await executor.execute(parsed.tool, arguments: arguments)
            XCTAssertEqual(try text(response), cli)
            XCTAssertTrue(cli.contains("[seq 1]"))
        }
        for arguments: [String: Any] in [[:], ["key": 42]] {
            let response = try await request(server, "tools/call", ["name": "vibebuddy_get_session", "arguments": arguments])
            XCTAssertEqual((response["error"] as? [String: Any])?["code"] as? Int, -32602)
        }
        for key in ["not-a-key", "codex:missing"] {
            let response = try await request(server, "tools/call", ["name": "vibebuddy_get_session", "arguments": ["key": key]])
            XCTAssertNil(response["error"])
            XCTAssertEqual((response["result"] as? [String: Any])?["isError"] as? Bool, true)
        }
        let source = try await request(server, "tools/call", ["name": "vibebuddy_get_session", "arguments": ["key": "codex:native"]])
        XCTAssertTrue(try text(source).contains("中文 context"))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).sorted(), ["codex"], "reading writes nothing")
        let status = try await request(server, "tools/call", ["name": "vibebuddy_live_status"])
        XCTAssertTrue(try text(status).contains("live status unknown"))
        XCTAssertEqual((status["result"] as? [String: Any])?["isError"] as? Bool, false)
    }

    func testMalformedJSONAndShapeAreProtocolErrors() async throws {
        let (root, reader) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let server = HistoryMCPServer(executor: HistoryToolExecutor(reader: reader, environment: ["VIBEBUDDY_PORT": "0"]))
        let response = try await server.response(to: Data("{".utf8))
        let invalid = try JSONSerialization.jsonObject(with: XCTUnwrap(response)) as! [String: Any]
        XCTAssertEqual((invalid["error"] as? [String: Any])?["code"] as? Int, -32700)
        _ = try await initialize(server)
        let shape = try await request(server, "tools/call", ["name": "vibebuddy_get_session", "arguments": []])
        XCTAssertEqual((shape["error"] as? [String: Any])?["code"] as? Int, -32602)
        XCTAssertThrowsError(try HistoryCLI.parse(["call", "vibebuddy_get_session", "[]"]))
        for arguments: [String: Any] in [["key": "k", "max_messages": true], ["key": "k", "tools": 1], ["key": "k", "max_messages": 1.5], ["key": "k", "unexpected": "x"]] {
            XCTAssertThrowsError(try HistoryTools.validateArguments("vibebuddy_get_session", arguments: arguments))
        }
    }
}
