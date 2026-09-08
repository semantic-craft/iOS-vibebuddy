import Foundation
import Testing
import NIOCore
import Hummingbird
import HummingbirdTesting
import VibeBuddyKit
@testable import VibeBuddyMacCore

@Suite("Dispatch route")
struct DispatchRouteTests {
    private func store(with directories: [String]) async -> SessionStore {
        let store = SessionStore()
        for (index, dir) in directories.enumerated() {
            await store.ingest(HookEvent(kind: .sessionStart, sessionID: "s\(index)", agent: .codex, cwd: dir,
                                         timestamp: Date().addingTimeInterval(Double(index))))
        }
        return store
    }

    @Test("a known directory starts the task; unknown directories, empty prompts and missing tokens are refused")
    func dispatch() async throws {
        let store = await store(with: ["/x/one", "/x/two"])
        #expect(await store.recentDirectories() == ["/x/two", "/x/one"])
        final class Box: @unchecked Sendable { var requests: [DispatchRequest] = [] }
        let box = Box()
        let srv = VibeBuddyServer(store: store, token: "t0k", port: 9876,
                                  onDispatch: { req in box.requests.append(req); return .started(sessionID: "thr-new") })
        try await srv.buildApplication().test(.router) { client in
            try await client.execute(uri: "/dispatch", method: .post,
                                     body: ByteBuffer(string: #"{"agent":"codex","cwd":"/x/one","prompt":"list files"}"#)) { res in
                #expect(res.status == .unauthorized)
            }
            try await client.execute(uri: "/dispatch", method: .post, headers: [.authorization: "Bearer t0k"],
                                     body: ByteBuffer(string: #"{"agent":"codex","cwd":"/elsewhere","prompt":"list files"}"#)) { res in
                #expect(res.status == .badRequest)
            }
            try await client.execute(uri: "/dispatch", method: .post, headers: [.authorization: "Bearer t0k"],
                                     body: ByteBuffer(string: #"{"agent":"codex","cwd":"/x/one","prompt":"   "}"#)) { res in
                #expect(res.status == .badRequest)
            }
            try await client.execute(uri: "/dispatch", method: .post, headers: [.authorization: "Bearer t0k"],
                                     body: ByteBuffer(string: #"{"agent":"codex","cwd":"/x/one","prompt":"list files","name":"listing"}"#)) { res in
                #expect(res.status == .ok)
                #expect(String(buffer: res.body).contains(#""sessionId":"thr-new""#))
            }
        }
        #expect(box.requests.count == 1)
        #expect(box.requests.first == DispatchRequest(agent: .codex, cwd: "/x/one", prompt: "list files", name: "listing"))
        // The snapshot tells the phone where it may start tasks.
        #expect(await store.snapshot(now: Date()).recentDirectories == ["/x/two", "/x/one"])
    }

    @Test("an agent without a launcher is 501; a missing Claude CLI and a disconnected Codex daemon are 503")
    func noLauncher() async throws {
        let store = await store(with: ["/x/one"])
        let socket = FileManager.default.temporaryDirectory.appendingPathComponent("vb-sock-\(UUID().uuidString)")
        let monitor = CodexAppServerMonitor(enabled: true, socketPath: socket.path)   // never connects: no socket file
        let srv = VibeBuddyServer(store: store, token: "t0k", port: 9876, codexAppServerMonitor: monitor,
                                  claudeLauncher: ClaudeBackgroundLauncher(executable: nil))
        try await srv.buildApplication().test(.router) { client in
            try await client.execute(uri: "/dispatch", method: .post, headers: [.authorization: "Bearer t0k"],
                                     body: ByteBuffer(string: #"{"agent":"qwen","cwd":"/x/one","prompt":"hi"}"#)) { res in
                #expect(res.status == .notImplemented)
            }
            try await client.execute(uri: "/dispatch", method: .post, headers: [.authorization: "Bearer t0k"],
                                     body: ByteBuffer(string: #"{"agent":"claudeCode","cwd":"/x/one","prompt":"hi"}"#)) { res in
                #expect(res.status == .serviceUnavailable)
            }
            try await client.execute(uri: "/dispatch", method: .post, headers: [.authorization: "Bearer t0k"],
                                     body: ByteBuffer(string: #"{"agent":"codex","cwd":"/x/one","prompt":"hi"}"#)) { res in
                #expect(res.status == .serviceUnavailable)
            }
        }
    }
}

@Suite("Codex dispatch through the daemon")
struct CodexDispatchTests {
    @Test("thread/start, an optional name, then turn/start; the new thread is subscribed and surfaces")
    func dispatch() async throws {
        let socket = FileManager.default.temporaryDirectory.appendingPathComponent("vb-sock-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: socket.path, contents: Data())
        defer { try? FileManager.default.removeItem(at: socket) }
        var results = fakeDaemonResults()
        results["thread/start"] = ["thread": ["id": "thr-new", "sessionId": "thr-new", "cwd": "/x/one", "source": "cli",
                                              "status": ["type": "idle"], "turns": []]]
        results["thread/name/set"] = [:]
        results["turn/start"] = ["turn": ["id": "t1", "items": [], "status": "inProgress"]]
        let connection = FakeConnection(results: results)
        let monitor = CodexAppServerMonitor(enabled: true, socketPath: socket.path, makeClient: { _ in connection })
        let store = SessionStore()
        let run = Task { await monitor.run(store: store) }
        defer { run.cancel(); connection.close() }
        #expect(await waitFor { await monitor.diagnostics().connected })

        let outcome = await monitor.dispatch(DispatchRequest(agent: .codex, cwd: "/x/one", prompt: "list files", name: "listing"))
        #expect(outcome == .started(sessionID: "thr-new"))
        #expect(connection.calls.suffix(3) == ["thread/start", "thread/name/set", "turn/start"])
        #expect(await monitor.diagnostics().subscribedThreads == 1)
        // The thread is known to the reducer, so its turn events will surface it.
        connection.push(["method": "turn/started", "params": ["threadId": "thr-new", "turn": ["id": "t1", "items": [], "status": "inProgress"]]])
        #expect(await waitFor { await store.snapshot(now: Date()).sessions.first { $0.id == "thr-new" }?.status == .working })
        #expect(await store.snapshot(now: Date()).sessions.first { $0.id == "thr-new" }?.project == "one")
    }
}

/// The wrist's stop, end to end inside the daemon: `/answer` → `AnswerDispatch`
/// → the app-server connection, with the HTTP result the phone reads.
@Suite("Stop route")
struct StopRouteTests {
    private struct Harness {
        let connection: FakeConnection
        let store = SessionStore()
        let monitor: CodexAppServerMonitor
        let socket: URL
        let run: Task<Void, Never>

        init() {
            socket = FileManager.default.temporaryDirectory.appendingPathComponent("vb-sock-\(UUID().uuidString)")
            FileManager.default.createFile(atPath: socket.path, contents: Data())
            var results = fakeDaemonResults()
            results["turn/interrupt"] = [:]
            connection = FakeConnection(results: results)
            monitor = CodexAppServerMonitor(enabled: true, socketPath: socket.path,
                                            makeClient: { [connection] _ in connection })
            let store = self.store
            let monitor = self.monitor
            run = Task { await monitor.run(store: store) }
        }

        func stop() { run.cancel(); connection.close(); try? FileManager.default.removeItem(at: socket) }

        /// A thread that is running a turn this connection saw start.
        func runningSession(_ id: String, turnID: String) async -> AgentSession? {
            guard await waitFor({ await monitor.diagnostics().connected }) else { return nil }
            connection.push(["method": "thread/status/changed",
                             "params": ["threadId": id, "status": ["type": "active", "activeFlags": []]]])
            connection.push(["method": "turn/started",
                             "params": ["threadId": id, "turn": ["id": turnID, "items": [], "status": "inProgress"]]])
            guard await waitFor({ await monitor.activeTurnID(threadID: id) == turnID }) else { return nil }
            return await store.snapshot(now: Date()).sessions.first { $0.id == id }
        }
    }

    @Test("a stop takes no text, interrupts once for a repeated tap, and separates refused from never-sent")
    func stopRoute() async throws {
        let h = Harness()
        defer { h.stop() }
        let session = try #require(await h.runningSession("thr-http", turnID: "t-1"))
        #expect(session.status == .working)
        let since = session.statusSince.timeIntervalSince1970
        let srv = VibeBuddyServer(store: h.store, token: "t0k", port: 9876, codexAppServerMonitor: h.monitor)
        @Sendable func body(_ requestID: String, since: Double) -> String {
            #"{"sessionId":"thr-http","intent":"stop","requestId":"\#(requestID)","expectedStatusSince":\#(since)}"#
        }
        try await srv.buildApplication().test(.router) { client in
            // No `answer` and no `answers`, which every other intent requires.
            for _ in 0..<2 {
                try await client.execute(uri: "/answer", method: .post, headers: [.authorization: "Bearer t0k"],
                                         body: ByteBuffer(string: body("r-1", since: since))) { res in
                    #expect(res.status == .ok)
                    #expect(String(buffer: res.body).contains(#""status":"accepted""#))
                }
            }
            // Aimed at a turn that is no longer the one running.
            try await client.execute(uri: "/answer", method: .post, headers: [.authorization: "Bearer t0k"],
                                     body: ByteBuffer(string: body("r-2", since: since + 5))) { res in
                #expect(res.status == .conflict)
                #expect(String(buffer: res.body).contains(#""status":"refused""#))
                #expect(String(buffer: res.body).contains("This task has changed"))
            }
            // A stop with something to say is a client bug, not an instruction.
            try await client.execute(uri: "/answer", method: .post, headers: [.authorization: "Bearer t0k"],
                                     body: ByteBuffer(string: #"{"sessionId":"thr-http","intent":"stop","requestId":"r-9","answer":"stop please"}"#)) { res in
                #expect(res.status == .badRequest)
            }
        }
        #expect(h.connection.calls.filter { $0 == "turn/interrupt" }.count == 1)

        // The daemon rejects the call: nothing happened, the client is told
        // why, and nothing else is tried in its place.
        h.connection.fail("turn/interrupt")
        let before = h.connection.calls.count
        try await srv.buildApplication().test(.router) { client in
            try await client.execute(uri: "/answer", method: .post, headers: [.authorization: "Bearer t0k"],
                                     body: ByteBuffer(string: body("r-3", since: since))) { res in
                #expect(res.status == .conflict)
                #expect(String(buffer: res.body).contains(#""status":"failed""#))
                #expect(String(buffer: res.body).contains("Codex refused the stop"))
            }
        }
        #expect(h.connection.calls.dropFirst(before) == ["turn/interrupt"])
    }
}
