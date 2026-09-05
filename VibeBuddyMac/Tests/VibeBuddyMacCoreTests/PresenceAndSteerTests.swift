import Foundation
import Testing
import NIOCore
import Hummingbird
import HummingbirdTesting
import VibeBuddyKit
@testable import VibeBuddyMacCore

@Suite("Presence policy")
struct PresencePolicyTests {
    private func input(focused: Bool = true, locked: Bool = false, idle: TimeInterval = 5,
                       alwaysAsk: Bool = false) -> PresencePolicy.Input {
        PresencePolicy.Input(sessionSurfaceFocused: focused, screenLocked: locked,
                             idleSeconds: idle, alwaysAskPhone: alwaysAsk)
    }

    @Test("at the keyboard with the session's terminal in front is present")
    func present() {
        #expect(PresencePolicy.decide(input()) == .present)
    }

    @Test("a locked screen, a long idle, another app in front, or the override each mean away")
    func away() {
        #expect(PresencePolicy.decide(input(locked: true)) == .away)
        #expect(PresencePolicy.decide(input(idle: PresencePolicy.idleThreshold)) == .away)
        #expect(PresencePolicy.decide(input(focused: false)) == .away)
        #expect(PresencePolicy.decide(input(alwaysAsk: true)) == .away)
        #expect(PresencePolicy.decide(input(idle: PresencePolicy.idleThreshold - 1)) == .present)
    }
}

/// The daemon lets the agent's own prompt take the answer while the person is
/// at the Mac, and shows the phone a read-only card.
@Suite("Presence-gated routes")
struct PresenceRoutesTests {
    private let request = #"{"hook_event_name":"PermissionRequest","session_id":"ps","cwd":"/x/p","permission_mode":"default","tool_name":"Bash","tool_input":{"command":"rm -rf build"}}"#
    private let ask = #"{"hook_event_name":"PreToolUse","session_id":"ps","cwd":"/x/p","tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"Which one?","header":"Pick","multiSelect":false,"options":[{"label":"A","description":"a"},{"label":"B","description":"b"}]}]}}"#

    private func server(store: SessionStore, present: Bool) -> VibeBuddyServer {
        VibeBuddyServer(store: store, token: "t0k", port: 9876,
                        approvalRegistry: ApprovalRegistry(),
                        rules: { _ in PermissionRules(allow: [], deny: []) },
                        allowStore: VibeBuddyAllowStore(url: FileManager.default.temporaryDirectory
                            .appendingPathComponent("vbp-\(UUID().uuidString).json")),
                        presence: { _ in present },
                        approvalTimeout: .seconds(5), approvalID: { "p1" })
    }

    @Test("present: the gate answers at once with no opinion and the card is read-only")
    func presentApproval() async throws {
        let store = SessionStore()
        try await server(store: store, present: true).buildApplication().test(.router) { client in
            try await client.execute(uri: "/approval", method: .post,
                headers: [.authorization: "Bearer t0k"], body: ByteBuffer(string: request)) { res in
                #expect(res.status == .ok)
                #expect(String(buffer: res.body).isEmpty)
            }
        }
        let session = try #require(await store.snapshot(now: Date()).sessions.first { $0.id == "ps" })
        #expect(session.status == .needsResponse)
        #expect(session.waitKind == .permission)
        #expect(session.pendingApproval?.isAnswerable == false)
        #expect(session.pendingApproval?.command == "rm -rf build")
        // Claude moved on after the terminal answer: the read-only card goes.
        await store.ingest(Data(#"{"hook_event_name":"PostToolUse","session_id":"ps","cwd":"/x/p","tool_name":"Bash","tool_response":{"stdout":""}}"#.utf8),
                           agent: .claudeCode, receivedAt: Date())
        let after = try #require(await store.snapshot(now: Date()).sessions.first { $0.id == "ps" })
        #expect(after.status == .working)
        #expect(after.pendingApproval == nil)
    }

    @Test("present: a question shows read-only and the hook prints nothing")
    func presentQuestion() async throws {
        let store = SessionStore()
        try await server(store: store, present: true).buildApplication().test(.router) { client in
            try await client.execute(uri: "/approval", method: .post,
                headers: [.authorization: "Bearer t0k"], body: ByteBuffer(string: ask)) { res in
                #expect(res.status == .ok)
                #expect(String(buffer: res.body).isEmpty)
            }
        }
        let session = try #require(await store.snapshot(now: Date()).sessions.first { $0.id == "ps" })
        #expect(session.waitKind == .question)
        #expect(session.pendingQuestion?.isAnswerable == false)
        #expect(session.pendingQuestion?.items.first?.options.map(\.label) == ["A", "B"])
    }

    @Test("away: the gate holds until the phone decides")
    func awayHolds() async throws {
        let store = SessionStore()
        try await server(store: store, present: false).buildApplication().test(.router) { client in
            async let held = client.execute(uri: "/approval", method: .post,
                headers: [.authorization: "Bearer t0k"], body: ByteBuffer(string: request)) { res -> String in
                String(buffer: res.body)
            }
            for _ in 0..<1000 {
                if await store.snapshot(now: Date()).sessions.first(where: { $0.id == "ps" })?.pendingApproval != nil { break }
                try await Task.sleep(for: .milliseconds(5))
            }
            #expect(await store.snapshot(now: Date()).sessions.first { $0.id == "ps" }?.pendingApproval?.isAnswerable == true)
            try await client.execute(uri: "/decision", method: .post,
                headers: [.authorization: "Bearer t0k"],
                body: ByteBuffer(string: #"{"approvalId":"p1","decision":"allow"}"#)) { res in
                #expect(res.status == .ok)
            }
            #expect(try await held.contains(#""behavior":"allow""#))
        }
    }
}

/// Free text for a Codex thread goes through the daemon, not a terminal.
@Suite("Codex steering")
struct CodexSteerTests {
    private struct Harness {
        let connection: FakeConnection
        let store = SessionStore()
        let monitor: CodexAppServerMonitor
        let socket: URL
        let run: Task<Void, Never>

        init(presence: Bool = false) {
            socket = FileManager.default.temporaryDirectory.appendingPathComponent("vb-sock-\(UUID().uuidString)")
            FileManager.default.createFile(atPath: socket.path, contents: Data())
            var results = fakeDaemonResults()
            results["turn/steer"] = ["turn": ["id": "t-s", "items": [], "status": "inProgress"]]
            results["turn/start"] = ["turn": ["id": "t-n", "items": [], "status": "inProgress"]]
            results["thread/resume"] = ["thread": ["id": "thr-live", "sessionId": "thr-live", "cwd": "/x/p", "source": "vscode",
                                                   "status": ["type": "idle"], "turns": []]]
            connection = FakeConnection(results: results)
            monitor = CodexAppServerMonitor(enabled: true, socketPath: socket.path,
                                            presence: { _ in presence },
                                            makeClient: { [connection] _ in connection })
            let store = self.store
            let monitor = self.monitor
            run = Task { await monitor.run(store: store) }
        }
        func stop() { run.cancel(); connection.close(); try? FileManager.default.removeItem(at: socket) }
        func connected() async -> Bool { await waitFor { await monitor.diagnostics().connected } }
        func activate(_ id: String) async {
            connection.push(["method": "thread/status/changed", "params": ["threadId": id, "status": ["type": "active", "activeFlags": []]]])
            _ = await waitFor { await store.snapshot(now: Date()).sessions.contains { $0.id == id } }
        }
    }

    @Test("a running thread is steered, an idle one gets a new turn, a cold one is resumed first")
    func steerPaths() async throws {
        let h = Harness()
        defer { h.stop() }
        #expect(await h.connected())
        await h.activate("thr-live")
        #expect(await h.monitor.steer(threadID: "thr-live", text: "also run the tests", isActive: true))
        #expect(h.connection.calls.last == "turn/steer")
        #expect(await h.monitor.steer(threadID: "thr-live", text: "start over", isActive: false))
        #expect(h.connection.calls.last == "turn/start")
        #expect(await h.monitor.steer(threadID: "thr-cold", text: "hello", isActive: false))
        #expect(h.connection.calls.suffix(2) == ["thread/resume", "turn/start"])
    }

    @Test("a steer the daemon refuses falls back to a new turn")
    func steerFallsBack() async throws {
        let h = Harness()
        defer { h.stop() }
        #expect(await h.connected())
        await h.activate("thr-x")
        h.connection.set("turn/steer", [:])       // the fake answers; remove to make it fail
        h.connection.fail("turn/steer")
        #expect(await h.monitor.steer(threadID: "thr-x", text: "hi", isActive: true))
        #expect(h.connection.calls.suffix(2) == ["turn/steer", "turn/start"])
    }

    @Test("the answer dispatch sends Codex text to the daemon and never types into a pane")
    func dispatchRoutesCodex() async throws {
        let store = SessionStore()
        await store.ingest(HookEvent(kind: .userPromptSubmit, sessionID: "thr-d", agent: .codex, cwd: "/x/p",
                                     observationSource: .appserver, timestamp: Date()))
        await store.setTerminalRef(sessionID: "thr-d", TerminalRef(termProgram: "tmux", tmux: "/tmp/s,1,0", tmuxPane: "%1"))
        final class Box: @unchecked Sendable { var steered: [(String, String, Bool)] = []; var typed: [String] = [] }
        let box = Box()
        let dispatch = AnswerDispatch(store: store, questions: QuestionRegistry(),
                                      inject: { _, text in box.typed.append(text) },
                                      steer: { id, text, active in box.steered.append((id, text, active)); return true })
        #expect(await dispatch.deliver(sessionID: "thr-d", text: "use postgres", answers: nil))
        #expect(box.typed.isEmpty)
        #expect(box.steered.count == 1)
        #expect(box.steered.first?.1 == "use postgres")
        #expect(box.steered.first?.2 == true)          // working → steer
    }

    @Test("present: an approval request shows a read-only card and is never answered from here")
    func presentReadOnly() async throws {
        let h = Harness(presence: true)
        defer { h.stop() }
        #expect(await h.connected())
        await h.activate("thr-p")
        h.connection.push(["id": 3, "method": "item/commandExecution/requestApproval",
                           "params": ["threadId": "thr-p", "turnId": "t", "itemId": "i", "kind": "command",
                                      "startedAtMs": 1, "environmentId": NSNull(), "command": "make", "cwd": "/x/p"]])
        #expect(await waitFor { await h.store.snapshot(now: Date()).sessions.first { $0.id == "thr-p" }?.pendingApproval != nil })
        let card = try #require(await h.store.snapshot(now: Date()).sessions.first { $0.id == "thr-p" }?.pendingApproval)
        #expect(card.isAnswerable == false)
        h.connection.push(["method": "serverRequest/resolved", "params": ["threadId": "thr-p", "requestId": 3]])
        #expect(await waitFor { await h.store.snapshot(now: Date()).sessions.first { $0.id == "thr-p" }?.pendingApproval == nil })
        #expect(h.connection.decisions.isEmpty)
    }
}
