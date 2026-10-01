import Foundation
import Testing
@testable import VibeBuddyMacCore

@Suite("Codex read-only task views")
struct CodexTaskReadsTests {
    @Test("Newest-first protocol pages become chronological rows without duplicates")
    func pagination() throws {
        let page = try CodexHistoryPage.decode([
            "data": [
                ["turnId": "turn", "item": ["id": "answer", "type": "agentMessage", "text": "done"]],
                ["turnId": "turn", "item": ["id": "prompt", "type": "userMessage", "content": [["type": "text", "text": "hello"]]]]
            ], "nextCursor": "opaque/=="
        ])
        #expect(page.messages.map(\.text) == ["hello", "done"])
        #expect(page.nextCursor == "opaque/==")
        let merged = CodexHistoryPage.prepend([page.messages[0]], to: page.messages)
        #expect(merged.count == 2)
        #expect(throws: CodexReadFailure.malformed) { try CodexHistoryPage.decode(["data": [["item": ["type": "agentMessage"]]]]) }
    }

    @Test("Live refresh preserves loaded older pages and updates overlapping items")
    func keepEarlierOnRefresh() {
        let old = (1...60).map { SessionHistoryMessage(id: "\($0)", role: .assistant, text: "old") }
        let latest = (36...65).map { SessionHistoryMessage(id: "\($0)", role: .assistant, text: "new") }
        let refreshed = CodexHistoryPage.refreshing(old, with: latest)
        #expect(refreshed.keptEarlier)
        #expect(refreshed.messages.map(\.id) == (1...65).map(String.init))
        #expect(refreshed.messages.first?.text == "old")
        #expect(refreshed.messages.last?.text == "new")
        let distant = [SessionHistoryMessage(id: "100", role: .assistant, text: "new")]
        #expect(!CodexHistoryPage.refreshing(old, with: distant).keptEarlier)
        #expect(CodexHistoryPage.refreshing(old, with: distant).messages.count == 1)
    }

    @Test("Read views send exact thread IDs and never resume or mutate a thread")
    func readBoundary() async throws {
        let socket = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        FileManager.default.createFile(atPath: socket.path, contents: Data())
        defer { try? FileManager.default.removeItem(at: socket) }
        var results = fakeDaemonResults()
        results["thread/goal/get"] = ["goal": ["threadId": "selected", "objective": "finish", "status": "active", "tokensUsed": 45, "timeUsedSeconds": 3, "updatedAt": 123]]
        results["thread/backgroundTerminals/list"] = ["data": [["processId": "p", "command": "sleep 30", "cwd": "/tmp"]]]
        results["thread/items/list"] = ["data": [], "nextCursor": "page-2"]
        let connection = FakeConnection(results: results)
        let monitor = CodexAppServerMonitor(socketPath: socket.path, makeClient: { _ in connection })
        let run = Task { await monitor.run(store: SessionStore()) }
        defer { run.cancel(); connection.close() }
        #expect(await waitFor { await monitor.diagnostics().connected })
        let goal = try await monitor.taskGoal(threadID: "selected").get()
        #expect(goal?.objective == "finish")
        let terminals = try await monitor.backgroundTerminals(threadID: "selected").get()
        #expect(terminals.data.first?.command == "sleep 30")
        let page = try await monitor.historyPage(threadID: "selected", cursor: "opaque").get()
        #expect(page.nextCursor == "page-2")
        #expect(connection.lastParams("thread/items/list")?["sortDirection"] as? String == "desc")
        #expect(connection.lastParams("thread/items/list")?["cursor"] as? String == "opaque")
        for method in ["thread/resume", "thread/start", "turn/start", "thread/goal/set", "thread/backgroundTerminals/terminate"] {
            #expect(connection.lastParams(method) == nil)
        }
        connection.set("thread/goal/get", ["goal": NSNull()])
        #expect(try await monitor.taskGoal(threadID: "selected").get() == nil)
        connection.set("thread/goal/get", ["goal": ["threadId": "other", "objective": "wrong", "status": "active", "tokensUsed": 0, "timeUsedSeconds": 0, "updatedAt": 0]])
        #expect(await monitor.taskGoal(threadID: "selected") == .failure(.malformed))
    }

    @Test("Disconnected is not an empty goal or empty terminal list")
    func disconnected() async {
        let monitor = CodexAppServerMonitor(socketPath: "/nonexistent/codex.sock")
        #expect(await monitor.taskGoal(threadID: "selected") == .failure(.disconnected))
        #expect(await monitor.backgroundTerminals(threadID: "selected") == .failure(.disconnected))
    }
}
