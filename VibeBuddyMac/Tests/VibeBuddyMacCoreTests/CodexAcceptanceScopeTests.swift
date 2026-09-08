import Foundation
import Testing
import VibeBuddyKit
@testable import VibeBuddyMacCore

@Suite("Codex acceptance task scope")
struct CodexAcceptanceScopeTests {
    @Test("An explicit task never lists, subscribes to or drives unrelated tasks")
    func oneTaskOnly() async throws {
        let socket = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        FileManager.default.createFile(atPath: socket.path, contents: Data())
        defer { try? FileManager.default.removeItem(at: socket) }
        var results = fakeDaemonResults()
        results["thread/resume"] = ["thread": ["id": "test-thread", "cwd": "/tmp/acceptance", "status": ["type": "idle"]]]
        let connection = FakeConnection(results: results)
        let store = SessionStore()
        let monitor = CodexAppServerMonitor(socketPath: socket.path, acceptanceThreadID: "test-thread",
                                            makeClient: { _ in connection })
        let task = Task { await monitor.run(store: store) }
        defer { task.cancel(); connection.close() }
        #expect(await waitFor { await monitor.diagnostics().subscribedThreads == 1 })
        #expect(connection.lastParams("thread/list") == nil)
        #expect(connection.lastParams("thread/resume")?["threadId"] as? String == "test-thread")
        connection.push(["method": "thread/status/changed", "params": ["threadId": "unrelated", "status": ["type": "active", "activeFlags": []]]])
        connection.push(["method": "thread/status/changed", "params": ["threadId": "test-thread", "status": ["type": "active", "activeFlags": []]]])
        #expect(await waitFor { await store.snapshot(now: Date()).sessions.first { $0.id == "test-thread" }?.status == .working })
        #expect(await store.snapshot(now: Date()).sessions.allSatisfy { $0.id == "test-thread" })
        #expect(await monitor.startTurn(threadID: "unrelated", text: "must not send") == false)
        #expect(await monitor.steer(threadID: "unrelated", text: "must not send") == false)
        if case .notSent = await monitor.interrupt(threadID: "unrelated") {} else { Issue.record("Unrelated stop was not refused") }
        #expect(connection.lastParams("turn/start") == nil)
        #expect(connection.lastParams("turn/steer") == nil)
        #expect(connection.lastParams("turn/interrupt") == nil)
        #expect(connection.lastParams("account/rateLimits/read") == nil)
    }
}
