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
                                     body: ByteBuffer(string: #"{"agent":"codex","cwd":"/x/one","prompt":"p","continuation":{"handoffPath":"/m/h.md"}}"#)) { res in
                #expect(res.status == .badRequest)
            }
            try await client.execute(uri: "/dispatch", method: .post, headers: [.authorization: "Bearer t0k"],
                                     body: ByteBuffer(string: #"{"agent":"codex","cwd":"/x/one","prompt":"list files","name":"listing"}"#)) { res in
                #expect(res.status == .ok)
                #expect(String(buffer: res.body).contains(#""sessionId":"thr-new""#))
            }
            // Cursor's model, mode and worktree ride the same body; an empty
            // model is no model.
            try await client.execute(uri: "/dispatch", method: .post, headers: [.authorization: "Bearer t0k"],
                                     body: ByteBuffer(string: #"{"agent":"cursor","cwd":"/x/one","prompt":"fix it","model":"gpt-5","mode":"plan","worktree":true}"#)) { res in
                #expect(res.status == .ok)
            }
            try await client.execute(uri: "/dispatch", method: .post, headers: [.authorization: "Bearer t0k"],
                                     body: ByteBuffer(string: #"{"agent":"cursor","cwd":"/x/one","prompt":"fix it","model":"","worktree":false}"#)) { res in
                #expect(res.status == .ok)
            }
            // Continue with…: the continuation reaches the launcher and the lineage is recorded (ADR-0023 amendment).
            try await client.execute(uri: "/dispatch", method: .post, headers: [.authorization: "Bearer t0k"],
                                     body: ByteBuffer(string: #"{"agent":"codex","cwd":"/x/one","prompt":"Continue from history.","continuation":{"sourceKey":"claude-code:src"}}"#)) { res in
                #expect(res.status == .ok)
            }
            #expect(box.requests.last?.continuation == DispatchContinuation(sourceKey: "claude-code:src", handoffPath: nil))
            // Once the receiver reports, the snapshot says what it continues.
            await store.ingest(HookEvent(kind: .userPromptSubmit, sessionID: "thr-new", agent: .codex, cwd: "/x/one", timestamp: Date(), turnID: "t"))
            #expect(await store.snapshot(now: Date()).sessions.first { $0.id == "thr-new" }?.continuesSessionKey == "claude-code:src")
        }
        #expect(box.requests.count == 4)
        #expect(box.requests.first == DispatchRequest(agent: .codex, cwd: "/x/one", prompt: "list files", name: "listing"))
        #expect(box.requests[1] == DispatchRequest(agent: .cursor, cwd: "/x/one", prompt: "fix it",
                                                   model: "gpt-5", mode: "plan", worktree: true))
        #expect(box.requests[2] == DispatchRequest(agent: .cursor, cwd: "/x/one", prompt: "fix it", worktree: false))
        // The snapshot tells the phone where it may start tasks.
        #expect(await store.snapshot(now: Date()).recentDirectories == ["/x/two", "/x/one"])
    }

    @Test("an unscanned handoff or mismatched source cannot reach a launcher")
    func rejectsUnverifiedHandoff() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("dispatch-handoff-" + UUID().uuidString)
        let directory = root.appendingPathComponent(".scratch/e/handoffs")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = directory.appendingPathComponent("h.md")
        try "Source session: claude-code:source\n".write(to: path, atomically: true, encoding: .utf8)
        let store = await store(with: [root.path])
        final class Box: @unchecked Sendable { var requests: [DispatchRequest] = [] }
        let box = Box()
        let server = VibeBuddyServer(store: store, token: "t0k", port: 9876,
                                    onDispatch: { req in box.requests.append(req); return .started(sessionID: "receiver") })
        try await server.buildApplication().test(.router) { client in
            for (handoff, source, accepted) in [
                ("/unrelated/.scratch/e/handoffs/fake.md", "claude-code:source", false),
                (path.path, "codex:wrong-source", false),
                (path.path, "claude-code:source", true)
            ] {
                let body = try JSONSerialization.data(withJSONObject: ["agent": "codex", "cwd": root.path, "prompt": "Continue",
                    "continuation": ["sourceKey": source, "handoffPath": handoff]])
                try await client.execute(uri: "/dispatch", method: .post, headers: [.authorization: "Bearer t0k"],
                                         body: ByteBuffer(bytes: body)) { response in
                    #expect(response.status == (accepted ? .ok : .badRequest))
                }
            }
        }
        #expect(box.requests.count == 1)
        #expect(box.requests.first?.continuation?.handoffPath == path.path)
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

/// Continue with… on the app-server (handoff-continue-hardening 03): the
/// receiver's `turn/start` carries the thread's own policy plus the handoff's
/// effort directory, and nothing else changes.
@Suite("Codex dispatch · Continue with…")
struct CodexContinueDispatchTests {
    private func harness(sandbox: [String: Any]?) async throws -> (CodexAppServerMonitor, FakeConnection, SessionStore, Task<Void, Never>, URL) {
        let socket = FileManager.default.temporaryDirectory.appendingPathComponent("vb-sock-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: socket.path, contents: Data())
        var results = fakeDaemonResults()
        var started: [String: Any] = ["thread": ["id": "thr-new", "sessionId": "thr-new", "cwd": "/x/one", "source": "cli",
                                                "status": ["type": "idle"], "turns": []]]
        if let sandbox { started["sandbox"] = sandbox }
        results["thread/start"] = started
        results["turn/start"] = ["turn": ["id": "t1", "items": [], "status": "inProgress"]]
        let connection = FakeConnection(results: results)
        let monitor = CodexAppServerMonitor(enabled: true, socketPath: socket.path, makeClient: { _ in connection })
        let store = SessionStore()
        let run = Task { await monitor.run(store: store) }
        #expect(await waitFor { await monitor.diagnostics().connected })
        return (monitor, connection, store, run, socket)
    }

    /// A real handoff path whose effort directory is outside `/x/one`.
    private func handoff() throws -> (path: String, root: String, tree: URL) {
        let tree = FileManager.default.temporaryDirectory.appendingPathComponent("main-" + UUID().uuidString)
        let handoffs = tree.appendingPathComponent(".scratch/effort/handoffs")
        try FileManager.default.createDirectory(at: handoffs, withIntermediateDirectories: true)
        let file = handoffs.appendingPathComponent("2026-09-14-claude-code-codex.md")
        try "Source session: claude-code:src\n".write(to: file, atomically: true, encoding: .utf8)
        let root = tree.appendingPathComponent(".scratch/effort").resolvingSymlinksInPath().standardizedFileURL.path
        return (file.path, root, tree)
    }

    @Test("workspace-write: the thread's roots plus exactly the handoff's effort directory; other fields untouched")
    func appendsOneRoot() async throws {
        let (monitor, connection, _, run, socket) = try await harness(sandbox: ["type": "workspaceWrite", "writableRoots": ["/x/one"], "networkAccess": true, "excludeSlashTmp": false])
        defer { run.cancel(); connection.close(); try? FileManager.default.removeItem(at: socket) }
        let h = try handoff()
        defer { try? FileManager.default.removeItem(at: h.tree) }
        let request = DispatchRequest(agent: .codex, cwd: "/x/one", prompt: "Read \(h.path), then continue.",
                                      continuation: DispatchContinuation(sourceKey: "claude-code:src", handoffPath: h.path))
        #expect(await monitor.dispatch(request) == .started(sessionID: "thr-new"))
        let turn = try #require(connection.params(of: "turn/start").last)
        let policy = try #require(turn["sandboxPolicy"] as? [String: Any])
        #expect(policy["type"] as? String == "workspaceWrite")
        #expect(policy["writableRoots"] as? [String] == ["/x/one", h.root])
        #expect(policy["networkAccess"] as? Bool == true)
        #expect(policy["excludeSlashTmp"] as? Bool == false)
        #expect(turn["approvalPolicy"] == nil)
    }

    @Test("inside the checkout, without a continuation, or under another policy: no sandboxPolicy is sent")
    func leavesThePolicyAlone() async throws {
        let h = try handoff()
        defer { try? FileManager.default.removeItem(at: h.tree) }
        // Inside the checkout: cwd is the tree the handoff lives in.
        do {
            let (monitor, connection, _, run, socket) = try await harness(sandbox: ["type": "workspaceWrite", "writableRoots": []])
            defer { run.cancel(); connection.close(); try? FileManager.default.removeItem(at: socket) }
            let inside = DispatchRequest(agent: .codex, cwd: h.tree.path, prompt: "p",
                                         continuation: DispatchContinuation(sourceKey: "claude-code:src", handoffPath: h.path))
            _ = await monitor.dispatch(inside)
            #expect(connection.params(of: "turn/start").last?["sandboxPolicy"] == nil)
        }
        // No continuation at all.
        do {
            let (monitor, connection, _, run, socket) = try await harness(sandbox: ["type": "workspaceWrite", "writableRoots": []])
            defer { run.cancel(); connection.close(); try? FileManager.default.removeItem(at: socket) }
            _ = await monitor.dispatch(DispatchRequest(agent: .codex, cwd: "/x/one", prompt: "p"))
            #expect(connection.params(of: "turn/start").last?["sandboxPolicy"] == nil)
        }
        // Read-only and full-access defaults are not widened; a daemon reporting no policy is not guessed at.
        for sandbox in [["type": "readOnly"] as [String: Any], ["type": "dangerFullAccess"]] + [nil] {
            let (monitor, connection, _, run, socket) = try await harness(sandbox: sandbox)
            defer { run.cancel(); connection.close(); try? FileManager.default.removeItem(at: socket) }
            _ = await monitor.dispatch(DispatchRequest(agent: .codex, cwd: "/x/one", prompt: "p",
                                                       continuation: DispatchContinuation(sourceKey: "claude-code:src", handoffPath: h.path)))
            #expect(connection.params(of: "turn/start").last?["sandboxPolicy"] == nil)
        }
    }

    @Test("writableRoot: the effort directory, nil inside the checkout or for a non-handoff path; the prompt's fallback line follows it")
    func writableRoot() throws {
        let h = try handoff()
        defer { try? FileManager.default.removeItem(at: h.tree) }
        #expect(ContinueWith.writableRoot(handoffPath: h.path, cwd: "/x/one") == h.root)
        #expect(ContinueWith.writableRoot(handoffPath: h.path, cwd: h.tree.path) == nil)
        #expect(ContinueWith.writableRoot(handoffPath: "/x/one/notes.md", cwd: "/x/one") == nil)
        let outside = ContinueWith.prompt(sessionKey: "claude-code:src", handoffPath: h.path, checkout: "/x/one")
        #expect(outside.contains("The handoff lives in \(h.root), outside this checkout; if your sandbox refuses to write there, report the text instead of writing."))
        let inside = ContinueWith.prompt(sessionKey: "claude-code:src", handoffPath: h.path, checkout: h.tree.path)
        #expect(!inside.contains("outside this checkout"))
        let edited = inside + "\nPreserve this user instruction."
        let moved = ContinueWith.promptForDispatch(edited, handoffPath: h.path, checkout: "/another/checkout")
        #expect(moved.contains("outside this checkout"))
        #expect(moved.contains("Preserve this user instruction."))
        #expect(ContinueWith.promptForDispatch(moved, handoffPath: h.path, checkout: h.tree.path) == edited)
        #expect(ContinueWith.promptForDispatch(moved, handoffPath: h.path, checkout: "/another/checkout") == moved)
    }
}
