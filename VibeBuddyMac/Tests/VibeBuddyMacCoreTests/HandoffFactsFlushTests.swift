import Testing
import Foundation
import NIOCore
import Hummingbird
import HummingbirdTesting
import VibeBuddyKit
@testable import VibeBuddyMacCore

/// PERF-01: the tool ledger writes at most every 10 s, but the handoff facts
/// tool reads it from another process right after the agent's last step.
@Suite("Tool ledger write-through for handoff facts")
struct HandoffFactsFlushTests {
    @Test("a facts call is recognised as CLI or MCP tool")
    func recognisesFactsCalls() {
        let now = Date()
        func record(_ tool: String, _ command: String?) -> ToolCallRecord {
            ToolCallRecord(id: "t", tool: tool, command: command, files: [], result: .unconfirmed, observedAt: now, source: "hook", coverage: "")
        }
        #expect(SessionStore.readsHandoffFacts(record("Bash", "vibebuddy-mcp facts claude-code:abc")))
        #expect(SessionStore.readsHandoffFacts(record("mcp__vibebuddy__vibebuddy_handoff_facts", nil)))
        #expect(SessionStore.readsHandoffFacts(record("Bash", "vibebuddy-mcp call vibebuddy_handoff_facts '{}'")))
        #expect(!SessionStore.readsHandoffFacts(record("Bash", "swift test")))
    }

    @Test("the steps before a facts call are on disk when the call runs")
    func factsCallWritesThrough() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("facts-flush-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = SessionStore(journalURL: dir.appendingPathComponent("lifecycle-journal.json"))
        let t0 = Date()
        func bash(_ event: String, _ id: String, _ command: String) -> Data {
            Data(#"{"hook_event_name":"\#(event)","session_id":"s","cwd":"/tmp","tool_name":"Bash","tool_use_id":"\#(id)","tool_input":{"command":"\#(command)"},"tool_response":{"stdout":"ok"}}"#.utf8)
        }
        _ = await store.ingest(Data(#"{"hook_event_name":"UserPromptSubmit","session_id":"s","cwd":"/tmp","prompt":"go"}"#.utf8), receivedAt: t0)
        // The first write opens the 10 s window; the test run lands inside it.
        _ = await store.ingest(bash("PreToolUse", "w", "echo warmup"), receivedAt: t0.addingTimeInterval(1))
        _ = await store.ingest(bash("PreToolUse", "a", "swift test"), receivedAt: t0.addingTimeInterval(2))
        _ = await store.ingest(bash("PostToolUse", "a", "swift test"), receivedAt: t0.addingTimeInterval(3))
        let held = try String(contentsOf: dir.appendingPathComponent("tool-ledger.json"), encoding: .utf8)
        #expect(!held.contains("swift test"))   // still inside the window
        _ = await store.ingest(bash("PreToolUse", "b", "vibebuddy-mcp facts claude-code:s"), receivedAt: t0.addingTimeInterval(4))
        let text = try String(contentsOf: dir.appendingPathComponent("tool-ledger.json"), encoding: .utf8)
        #expect(text.contains("swift test"))
    }

    @Test("a Stop from any source writes the held steps")
    func nonHookStopWritesThrough() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("facts-stop-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = SessionStore(journalURL: dir.appendingPathComponent("lifecycle-journal.json"))
        let t0 = Date()
        func bash(_ event: String, _ id: String, _ command: String) -> Data {
            Data(#"{"hook_event_name":"\#(event)","session_id":"s","cwd":"/tmp","tool_name":"Bash","tool_use_id":"\#(id)","tool_input":{"command":"\#(command)"},"tool_response":{"stdout":"ok"}}"#.utf8)
        }
        _ = await store.ingest(bash("PreToolUse", "w", "echo warmup"), receivedAt: t0)
        _ = await store.ingest(bash("PreToolUse", "a", "swift test"), receivedAt: t0.addingTimeInterval(1))
        let held = try String(contentsOf: dir.appendingPathComponent("tool-ledger.json"), encoding: .utf8)
        #expect(!held.contains("swift test"))
        await store.ingest(HookEvent(kind: .stop, sessionID: "s", agent: .claudeCode,
                                     observationSource: .transcript, timestamp: t0.addingTimeInterval(2)))
        let text = try String(contentsOf: dir.appendingPathComponent("tool-ledger.json"), encoding: .utf8)
        #expect(text.contains("swift test"))
    }

    @Test("/ledger/flush is token-gated and writes the held steps")
    func flushRoute() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("facts-route-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = SessionStore(journalURL: dir.appendingPathComponent("lifecycle-journal.json"))
        let t0 = Date()
        func bash(_ id: String, _ command: String) -> Data {
            Data(#"{"hook_event_name":"PreToolUse","session_id":"s","cwd":"/tmp","tool_name":"Bash","tool_use_id":"\#(id)","tool_input":{"command":"\#(command)"}}"#.utf8)
        }
        _ = await store.ingest(bash("w", "echo warmup"), receivedAt: t0)
        _ = await store.ingest(bash("a", "swift test"), receivedAt: t0.addingTimeInterval(1))
        let ledger = dir.appendingPathComponent("tool-ledger.json")
        #expect(!(try String(contentsOf: ledger, encoding: .utf8)).contains("swift test"))
        let srv = VibeBuddyServer(store: store, token: "t0k", port: 9876)
        try await srv.buildApplication().test(.router) { client in
            try await client.execute(uri: "/ledger/flush", method: .post) { res in
                #expect(res.status == .unauthorized)
            }
            #expect(!(try String(contentsOf: ledger, encoding: .utf8)).contains("swift test"))
            try await client.execute(uri: "/ledger/flush", method: .post, headers: [.authorization: "Bearer t0k"]) { res in
                #expect(res.status == .noContent)
            }
        }
        #expect(try String(contentsOf: ledger, encoding: .utf8).contains("swift test"))
    }

    @Test("the flush request refuses an invalid VIBEBUDDY_PORT instead of falling back to 9876")
    func flushRequestPort() throws {
        let base = ["VIBEBUDDY_TOKEN": "t0k"]
        let valid = try #require(LedgerFlushRequest.request(environment: base.merging(["VIBEBUDDY_PORT": "9877"]) { $1 }))
        #expect(valid.url?.absoluteString == "http://127.0.0.1:9877/ledger/flush")
        #expect(valid.value(forHTTPHeaderField: "Authorization") == "Bearer t0k")
        #expect(LedgerFlushRequest.request(environment: base)?.url?.port == 9876)
        for bad in ["abc", "0", "70000", " 9877", ""] {
            #expect(LedgerFlushRequest.request(environment: base.merging(["VIBEBUDDY_PORT": bad]) { $1 }) == nil)
        }
        #expect(LedgerFlushRequest.request(environment: base.merging(["VIBEBUDDY_FACTS_DIRECTORY": "/x"]) { $1 }) == nil)
        #expect(LedgerFlushRequest.request(environment: ["VIBEBUDDY_TOKEN": "a\nb"]) == nil)
    }
}
