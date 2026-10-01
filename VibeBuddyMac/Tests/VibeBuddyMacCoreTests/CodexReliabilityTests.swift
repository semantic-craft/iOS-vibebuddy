import Foundation
import Darwin
import Testing
import VibeBuddyKit
@testable import VibeBuddyMacCore

@Suite("Codex bounded observation and recovery")
struct CodexReliabilityTests {
    @Test("delta burst retains no messages; lifecycle overflow is explicit and bounded")
    func boundedBurst() async throws {
        let client = CodexAppServerClient()
        let delta = try JSONSerialization.data(withJSONObject: ["method": "item/agentMessage/delta", "params": ["delta": String(repeating: "a", count: 1024)]])
        var baselineSink: AsyncStream<Data>.Continuation!
        let baseline = AsyncStream<Data>(bufferingPolicy: .unbounded) { baselineSink = $0 }
        let baselineStart = ContinuousClock.now
        let memoryBefore = allocatedBytes()
        for _ in 0..<10_000 {
            baselineSink.yield(delta.withUnsafeBytes { Data(bytes: $0.baseAddress!, count: $0.count) })
        }
        let baselineMemory = allocatedBytes()
        baselineSink.finish()
        var baselineBytes = 0
        for await raw in baseline { baselineBytes += raw.count }
        let baselineElapsed = baselineStart.duration(to: .now)
        let start = ContinuousClock.now
        let optimizedMemoryBefore = allocatedBytes()
        for _ in 0..<10_000 {
            client.dispatch(delta.withUnsafeBytes { Data(bytes: $0.baseAddress!, count: $0.count) })
        }
        let optimizedMemory = allocatedBytes()
        let deltaElapsed = start.duration(to: .now)
        #expect(!client.requiresResynchronization)
        let lifecycle = try JSONSerialization.data(withJSONObject: ["method": "turn/started", "params": ["threadId": "t", "turn": ["id": "turn"]]])
        for _ in 0...CodexAppServerClient.messageCapacity { client.dispatch(lifecycle) }
        #expect(client.requiresResynchronization)
        var retained = 0
        for await _ in client.messages { retained += 1 }
        #expect(retained == CodexAppServerClient.messageCapacity)
        print("Codex burst: input=10000 deltaBytes=\(delta.count * 10000) retainedDeltaBytes=0 lifecycleCap=\(retained) elapsed=\(deltaElapsed) baselineRetainedWireBytes=\(baselineBytes) baselineEnqueueAndDrain=\(baselineElapsed) baselineAllocatedDelta=\(Int64(baselineMemory) - Int64(memoryBefore)) filteredAllocatedDelta=\(Int64(optimizedMemory) - Int64(optimizedMemoryBefore))")
    }

    @Test("repeated completion and usage do not repeat normalized events")
    func duplicates() {
        var reducer = CodexAppServerReducer()
        _ = reducer.seed(thread: ["id": "t", "source": "cli", "status": ["type": "active"]], receivedAt: Date())
        let complete: [String: Any] = ["method": "turn/completed", "params": ["threadId": "t", "turn": ["id": "turn", "status": "completed", "items": [["type": "agentMessage", "phase": "final_answer", "text": "Done"]]]]]
        #expect(reducer.handle(complete, receivedAt: Date()).count == 1)
        #expect(reducer.handle(complete, receivedAt: Date()).isEmpty)
        let usage: [String: Any] = ["method": "thread/tokenUsage/updated", "params": ["threadId": "t", "tokenUsage": ["last": ["totalTokens": 10], "total": ["totalTokens": 100]]]]
        #expect(reducer.handle(usage, receivedAt: Date()).count == 1)
        #expect(reducer.handle(usage, receivedAt: Date()).isEmpty)
    }

    @Test("reconnect recovers the lost terminal turn from persisted history")
    func reconnectRecovery() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let socket = directory.appendingPathComponent("socket")
        FileManager.default.createFile(atPath: socket.path, contents: Data())
        let store = SessionStore(journalURL: directory.appendingPathComponent("journal.json"))
        let first = FakeConnection(results: fakeDaemonResults())
        var results = fakeDaemonResults()
        results["thread/turns/list"] = ["data": [["id": "turn", "status": "completed", "items": [["type": "agentMessage", "phase": "final_answer", "text": "Recovered full result"]]]]]
        let second = FakeConnection(results: results)
        let factory = ReconnectFactory(first: first, second: second)
        let monitor = CodexAppServerMonitor(socketPath: socket.path, minimumBackoff: .milliseconds(10), maximumBackoff: .milliseconds(20), makeClient: { _ in factory.next() })
        let run = Task { await monitor.run(store: store) }
        #expect(await waitFor { await monitor.diagnostics().connected })
        first.push(["method": "turn/started", "params": ["threadId": "t", "turn": ["id": "turn"]]])
        #expect(await waitFor { await store.snapshot(now: Date()).sessions.first(where: { $0.id == "t" })?.status == .working })
        first.close()
        #expect(await waitFor { await store.snapshot(now: Date()).sessions.first(where: { $0.id == "t" })?.completionText == "Recovered full result" })
        #expect(second.params(of: "thread/turns/list").count == 1)
        #expect(second.params(of: "turn/start").isEmpty)
        #expect(await store.snapshot(now: Date()).sessions.first(where: { $0.id == "t" })?.status == .done)
        run.cancel(); second.close(); await run.value
        try FileManager.default.removeItem(at: directory)
    }

    @Test("an unrecoverable old turn does not block discovery or fabricate completion", arguments: [false, true])
    func recoveryFailureIsolation(readFails: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let socket = directory.appendingPathComponent("socket")
        FileManager.default.createFile(atPath: socket.path, contents: Data())
        let store = SessionStore(journalURL: directory.appendingPathComponent("journal.json"))
        let first = FakeConnection(results: fakeDaemonResults())
        let newThread: [String: Any] = ["id": "new", "source": "cli", "cwd": "/test", "status": ["type": "idle"]]
        var results = fakeDaemonResults()
        results["thread/list"] = ["data": [newThread]]
        results["thread/resume"] = ["thread": newThread]
        // Empty pages with a cursor exhaust the four-page bound. The alternate
        // case returns an RPC error for a deleted/unreadable thread instead.
        if !readFails { results["thread/turns/list"] = ["data": [], "nextCursor": "more"] }
        let second = FakeConnection(results: results)
        let factory = ReconnectFactory(first: first, second: second)
        let monitor = CodexAppServerMonitor(socketPath: socket.path, minimumBackoff: .milliseconds(10), maximumBackoff: .milliseconds(20), makeClient: { _ in factory.next() })
        let run = Task { await monitor.run(store: store) }
        #expect(await waitFor { await monitor.diagnostics().connected })
        first.push(["method": "turn/started", "params": ["threadId": "old", "turn": ["id": "lost-turn"]]])
        #expect(await waitFor { await store.snapshot(now: Date()).sessions.first(where: { $0.id == "old" })?.status == .working })
        first.close()
        #expect(await waitFor { await monitor.diagnostics().subscribedThreads == 1 })
        #expect(await monitor.diagnostics().uncertainThreads == 1)
        #expect(second.params(of: "thread/list").count == 1)
        #expect(second.params(of: "thread/turns/list").count == (readFails ? 1 : 4))
        second.push(["method": "turn/started", "params": ["threadId": "new", "turn": ["id": "new-turn"]]])
        #expect(await waitFor { await store.snapshot(now: Date()).sessions.first(where: { $0.id == "new" })?.status == .working })
        let old = await store.snapshot(now: Date()).sessions.first(where: { $0.id == "old" })
        #expect(old?.status == .working)
        #expect(old?.completionID == nil)
        #expect(old?.completionText == nil)
        second.push(["method": "turn/completed", "params": ["threadId": "new", "turn": ["id": "new-turn", "status": "completed", "items": []]]])
        #expect(await waitFor { await store.snapshot(now: Date()).sessions.first(where: { $0.id == "new" })?.status == .done })
        #expect(await monitor.diagnostics().uncertainThreads == 1)
        // Other tasks' live events must not restore the stale global lease.
        await store.ingest(HookEvent(kind: .stop, sessionID: "old", agent: .codex,
            observationSource: .rollout, timestamp: Date(), turnID: "lost-turn",
            completionText: "Fallback observed the real ending", completionSucceeded: true))
        #expect(await store.snapshot(now: Date()).sessions.first(where: { $0.id == "old" })?.status == .done)
        // An actual terminal message for this exact lost turn discharges the
        // uncertainty even when the earlier history read failed.
        second.push(["method": "turn/completed", "params": ["threadId": "old", "turn": ["id": "lost-turn", "status": "completed", "items": []]]])
        #expect(await waitFor { await monitor.diagnostics().uncertainThreads == 0 })
        run.cancel(); second.close(); await run.value
        try FileManager.default.removeItem(at: directory)
    }

    @Test("an old completion replay preserves the newer turn and its recovery identity")
    func oldCompletionCannotEndNewTurn() {
        var reducer = CodexAppServerReducer()
        let first: [String: Any] = ["method": "turn/completed", "params": ["threadId": "t", "turn": ["id": "r1", "status": "completed", "items": []]]]
        #expect(reducer.handle(first, receivedAt: Date()).count == 1)
        _ = reducer.handle(["method": "turn/started", "params": ["threadId": "t", "turn": ["id": "r2"]]], receivedAt: Date())
        #expect(reducer.handle(first, receivedAt: Date()).isEmpty)
        #expect(reducer.threads["t"]?.activeTurnID == "r2")
        #expect(reducer.activeThreadIDs.contains("t"))
        let tool = reducer.handle(["method": "item/started", "params": ["threadId": "t", "turnId": "r2", "item": ["id": "item", "type": "commandExecution", "command": "true"]]], receivedAt: Date())
        #expect(tool.count == 1)
    }

    @Test("read overload retries at most three times; write methods never enter retry")
    func selectiveRetries() async throws {
        let client = OverloadedConnection()
        let monitor = CodexAppServerMonitor()
        do {
            _ = try await monitor.readWithRetry(client: client, method: "thread/read", params: ["threadId": "t"])
            Issue.record("overloaded read must fail")
        } catch CodexAppServerClient.ClientError.rpc(let code, _) { #expect(code == -32001) }
        #expect(client.count == 3)
        do {
            _ = try await monitor.readWithRetry(client: client, method: "turn/start", params: [:])
            Issue.record("control write must be refused")
        } catch CodexAppServerClient.ClientError.malformed {}
        #expect(client.count == 3)
    }
}

private final class OverloadedConnection: CodexAppServerConnecting, @unchecked Sendable {
    let messages = AsyncStream<Data> { $0.finish() }
    private let lock = NSLock()
    private var calls = 0
    var count: Int { lock.withLock { calls } }
    func connect() throws {}
    func close() {}
    func notify(_ method: String, params: [String: Any]?) {}
    func respond(id: JSONRPCID, result: [String: Any]) {}
    func request(_ method: String, params: [String: Any], timeout: Duration) async throws -> [String: Any] {
        lock.withLock { calls += 1 }
        throw CodexAppServerClient.ClientError.rpc(code: -32001, message: "Server overloaded")
    }
}

private final class ReconnectFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var first: FakeConnection?
    private let second: FakeConnection
    init(first: FakeConnection, second: FakeConnection) { self.first = first; self.second = second }
    func next() -> FakeConnection {
        lock.withLock {
            if let connection = first { first = nil; return connection }
            return second
        }
    }
}

private func allocatedBytes() -> UInt64 {
    var statistics = malloc_statistics_t()
    malloc_zone_statistics(nil, &statistics)
    return UInt64(statistics.size_in_use)
}
