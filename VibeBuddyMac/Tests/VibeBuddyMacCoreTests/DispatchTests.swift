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

    @Test("without a launcher, Claude is 501 and a disconnected Codex daemon is 503")
    func noLauncher() async throws {
        let store = await store(with: ["/x/one"])
        let socket = FileManager.default.temporaryDirectory.appendingPathComponent("vb-sock-\(UUID().uuidString)")
        let monitor = CodexAppServerMonitor(enabled: true, socketPath: socket.path)   // never connects: no socket file
        let srv = VibeBuddyServer(store: store, token: "t0k", port: 9876, codexAppServerMonitor: monitor)
        try await srv.buildApplication().test(.router) { client in
            try await client.execute(uri: "/dispatch", method: .post, headers: [.authorization: "Bearer t0k"],
                                     body: ByteBuffer(string: #"{"agent":"claude","cwd":"/x/one","prompt":"hi"}"#)) { res in
                #expect(res.status == .notImplemented)
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
