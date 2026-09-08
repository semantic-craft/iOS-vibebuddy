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
        /// The turn id only ever arrives with `turn/started`; without it a stop
        /// has nothing to name.
        func startTurn(_ id: String, turnID: String) async {
            connection.push(["method": "turn/started",
                             "params": ["threadId": id, "turn": ["id": turnID, "items": [], "status": "inProgress"]]])
            _ = await waitFor { await monitor.activeTurnID(threadID: id) == turnID }
        }
    }

    @Test("a running thread is steered, an idle one gets a new turn, a cold one is resumed first")
    func steerPaths() async throws {
        let h = Harness()
        defer { h.stop() }
        #expect(await h.connected())
        await h.activate("thr-live")
        #expect(await h.monitor.steer(threadID: "thr-live", text: "also run the tests"))
        #expect(h.connection.calls.last == "turn/steer")
        #expect(await h.monitor.startTurn(threadID: "thr-live", text: "start over"))
        #expect(h.connection.calls.last == "turn/start")
        #expect(await h.monitor.startTurn(threadID: "thr-cold", text: "hello"))
        #expect(h.connection.calls.suffix(2) == ["thread/resume", "turn/start"])
    }

    @Test("a steer the daemon refuses does not start a new turn")
    func steerFailureDoesNotStart() async throws {
        let h = Harness()
        defer { h.stop() }
        #expect(await h.connected())
        await h.activate("thr-x")
        h.connection.set("turn/steer", [:])
        h.connection.fail("turn/steer")
        #expect(await h.monitor.steer(threadID: "thr-x", text: "hi") == false)
        #expect(h.connection.calls.last == "turn/steer")
        #expect(!h.connection.calls.contains("turn/start"))
    }

    @Test("a stop sends turn/interrupt once, with the turn id the method requires")
    func interruptCarriesTheTurnID() async throws {
        let h = Harness()
        defer { h.stop() }
        #expect(await h.connected())
        await h.activate("thr-i")
        h.connection.set("turn/interrupt", [:])
        // Attached mid-turn: no turn/started was seen, so there is nothing to
        // name. That is a definite "not sent", not an unknown.
        let noTurn = await h.monitor.interrupt(threadID: "thr-i")
        if case .notSent = noTurn {} else { Issue.record("expected notSent, got \(noTurn)") }
        #expect(!h.connection.calls.contains("turn/interrupt"))

        await h.startTurn("thr-i", turnID: "t-7")
        #expect(await h.monitor.interrupt(threadID: "thr-i") == .sent)
        #expect(h.connection.calls.last == "turn/interrupt")
        let params = try #require(h.connection.lastParams("turn/interrupt"))
        #expect(params["threadId"] as? String == "thr-i")
        #expect(params["turnId"] as? String == "t-7")
    }

    @Test("a turn we stopped ends as an ending, not as a crash")
    func stoppedTurnIsNotAFailure() async throws {
        let h = Harness()
        defer { h.stop() }
        #expect(await h.connected())
        await h.activate("thr-q")
        h.connection.set("turn/interrupt", [:])
        await h.startTurn("thr-q", turnID: "t-1")
        #expect(await h.monitor.interrupt(threadID: "thr-q") == .sent)
        // Codex answers a stop and a crash with the same word.
        h.connection.push(["method": "turn/completed",
                           "params": ["threadId": "thr-q",
                                      "turn": ["id": "t-1", "status": "interrupted", "items": []]]])
        #expect(await waitFor { await h.store.snapshot(now: Date()).sessions.first { $0.id == "thr-q" }?.status == .done })
        let stopped = try #require(await h.store.snapshot(now: Date()).sessions.first { $0.id == "thr-q" })
        #expect(stopped.userStopped == true)
        #expect(stopped.failed != true)
        #expect(stopped.isStuck == false)
        // Nothing to go back and read: they know how it ended.
        #expect(stopped.hasUnreadCompletion == false)
        // And the wrist stays quiet instead of ringing the error cue. (Drop the
        // `userStopped` guard in SoundPolicy and this rings `agentStuck`: the
        // summary still says "Turn interrupted".)
        let policy = SoundPolicy()
        let running = AgentSession(id: "thr-q", agent: .codex, project: "p", status: .working,
                                   statusSince: Date().addingTimeInterval(-120), updatedAt: Date())
        let seed = SoundPolicyInput(sessions: [running], now: Date(), appActive: false, quietMode: false)
        _ = policy.evaluate(seed)          // first snapshot never rings
        _ = policy.evaluate(seed)
        #expect(policy.evaluate(SoundPolicyInput(sessions: [stopped], now: Date(),
                                                 appActive: false, quietMode: false)).isEmpty)

        // The next turn on the same session is an ordinary turn again.
        await h.startTurn("thr-q", turnID: "t-2")
        #expect(await waitFor { await h.store.snapshot(now: Date()).sessions.first { $0.id == "thr-q" }?.userStopped == nil })
    }

    @Test("an interruption nobody asked us for still reads as a failure")
    func externalInterruptStillFails() async throws {
        let h = Harness()
        defer { h.stop() }
        #expect(await h.connected())
        await h.activate("thr-x2")
        await h.startTurn("thr-x2", turnID: "t-9")
        // Somebody pressed stop in Codex Desktop; this Mac asked for nothing.
        h.connection.push(["method": "turn/completed",
                           "params": ["threadId": "thr-x2",
                                      "turn": ["id": "t-9", "status": "interrupted", "items": []]]])
        #expect(await waitFor { await h.store.snapshot(now: Date()).sessions.first { $0.id == "thr-x2" }?.status == .done })
        let ended = try #require(await h.store.snapshot(now: Date()).sessions.first { $0.id == "thr-x2" })
        #expect(ended.userStopped == nil)
        #expect(ended.failed == true)
    }

    @Test("a stop the daemon rejects is not retried and reaches for no other method")
    func interruptFailureStopsThere() async throws {
        let h = Harness()
        defer { h.stop() }
        #expect(await h.connected())
        await h.activate("thr-k")
        await h.startTurn("thr-k", turnID: "t-9")
        h.connection.fail("turn/interrupt")
        let before = h.connection.calls.count
        // The daemon answered with a JSON-RPC error, so the stop definitely did
        // not happen — that is `notSent`, not an unknown.
        let refused = await h.monitor.interrupt(threadID: "thr-k")
        if case .notSent = refused {} else { Issue.record("expected notSent, got \(refused)") }
        // One call, and nothing after it: no retry, no resume, no other turn method.
        #expect(h.connection.calls.dropFirst(before) == ["turn/interrupt"])
    }

    @Test("the answer dispatch sends Codex text to the daemon and never types into a pane")
    func dispatchRoutesCodex() async throws {
        let store = SessionStore()
        await store.ingest(HookEvent(kind: .userPromptSubmit, sessionID: "thr-d", agent: .codex, cwd: "/x/p",
                                     observationSource: .appserver, timestamp: Date()))
        await store.setTerminalRef(sessionID: "thr-d", TerminalRef(termProgram: "tmux", tmux: "/tmp/s,1,0", tmuxPane: "%1"))
        final class Box: @unchecked Sendable { var steered: [String] = []; var started: [String] = []; var typed: [String] = [] }
        let box = Box()
        let dispatch = AnswerDispatch(store: store, questions: QuestionRegistry(),
                                      inject: { _, text in box.typed.append(text) },
                                      steer: { _, text in box.steered.append(text); return true },
                                      startTurn: { _, text in box.started.append(text); return true })
        #expect(await dispatch.deliver(sessionID: "thr-d", text: "use postgres", answers: nil))
        #expect(box.typed.isEmpty)
        #expect(box.steered == ["use postgres"])
        #expect(box.started.isEmpty)
    }

    @Test("an expired Answer does not become a steer")
    func expiredAnswerDoesNotSteer() async throws {
        let store = SessionStore()
        await store.ingest(HookEvent(kind: .userPromptSubmit, sessionID: "thr-e", agent: .codex, cwd: "/x/p",
                                     observationSource: .appserver, timestamp: Date()))
        final class Box: @unchecked Sendable { var steered = 0; var started = 0 }
        let box = Box()
        let dispatch = AnswerDispatch(store: store, questions: QuestionRegistry(),
                                      inject: { _, _ in },
                                      steer: { _, _ in box.steered += 1; return true },
                                      startTurn: { _, _ in box.started += 1; return true })
        let result = await dispatch.deliver(SessionActionRequest(
            sessionID: "thr-e", intent: .answer, requestID: "r1",
            questionID: "q-old", text: "yes"))
        #expect(result == .failed("This question is no longer waiting"))
        #expect(box.steered == 0)
        #expect(box.started == 0)
    }

    @Test("a duplicate requestId is not executed again")
    func duplicateRequestIdIsNotReplayed() async throws {
        let store = SessionStore()
        await store.ingest(HookEvent(kind: .userPromptSubmit, sessionID: "thr-dup", agent: .codex, cwd: "/x/p",
                                     observationSource: .appserver, timestamp: Date()))
        final class Box: @unchecked Sendable { var steered = 0 }
        let box = Box()
        let dispatch = AnswerDispatch(store: store, questions: QuestionRegistry(),
                                      inject: { _, _ in },
                                      steer: { _, _ in box.steered += 1; return true })
        let request = SessionActionRequest(sessionID: "thr-dup", intent: .steer,
                                           requestID: "same", text: "retry")
        #expect(await dispatch.deliver(request) == .accepted)
        #expect(await dispatch.deliver(request) == .accepted)
        #expect(box.steered == 1)
    }

    /// One running Codex session and a box recording every channel a dispatch
    /// could reach for, so a stop can be shown to touch exactly one.
    private struct StopFixture {
        final class Box: @unchecked Sendable {
            var interrupted: [String] = []
            var steered = 0
            var started = 0
            var typed = 0
        }
        let store = SessionStore()
        let box = Box()

        func session(_ id: String, agent: AgentKind, finished: Bool = false) async -> AgentSession {
            await store.ingest(HookEvent(kind: finished ? .stop : .userPromptSubmit, sessionID: id,
                                         agent: agent, cwd: "/x/p",
                                         observationSource: .appserver, timestamp: Date()))
            return await store.snapshot(now: Date()).sessions.first { $0.id == id }!
        }

        func dispatch(_ outcome: CodexAppServerMonitor.InterruptOutcome = .sent) -> AnswerDispatch {
            AnswerDispatch(store: store, questions: QuestionRegistry(),
                           inject: { _, _ in box.typed += 1 },
                           steer: { _, _ in box.steered += 1; return true },
                           startTurn: { _, _ in box.started += 1; return true },
                           interrupt: { id in box.interrupted.append(id); return outcome })
        }

        func stop(_ id: String, since: Date?, requestID: String = UUID().uuidString) -> SessionActionRequest {
            SessionActionRequest(sessionID: id, intent: .stop, requestID: requestID,
                                 expectedStatusSince: since?.timeIntervalSince1970)
        }
    }

    @Test("a stop on the running turn interrupts once, whatever the tap count")
    func stopInterruptsTheRunningTurn() async throws {
        let f = StopFixture()
        let session = await f.session("thr-stop", agent: .codex)
        #expect(session.status == .working)
        let dispatch = f.dispatch()
        let request = f.stop("thr-stop", since: session.statusSince, requestID: "same")
        #expect(await dispatch.deliver(request) == .accepted)
        #expect(await dispatch.deliver(request) == .accepted)
        #expect(f.box.interrupted == ["thr-stop"])
        // A stop is never any of the other three things.
        #expect(f.box.steered == 0)
        #expect(f.box.started == 0)
        #expect(f.box.typed == 0)
    }

    @Test("a stop that never went out says so; one that went out unanswered stays unknown")
    func stopThatDoesNotLand() async throws {
        let f = StopFixture()
        let session = await f.session("thr-dead", agent: .codex)
        // Nothing was sent: the client learns the reason and that retrying the
        // same request is pointless.
        #expect(await f.dispatch(.notSent("Your Mac isn't connected to Codex right now."))
            .deliver(f.stop("thr-dead", since: session.statusSince))
                == .failed("Your Mac isn't connected to Codex right now."))
        // It went out and the connection died: genuinely unknown.
        #expect(await f.dispatch(.unconfirmed).deliver(f.stop("thr-dead", since: session.statusSince))
                == .unknown)
        #expect(f.box.interrupted == ["thr-dead", "thr-dead"])
        #expect(f.box.steered == 0)
        #expect(f.box.started == 0)
        #expect(f.box.typed == 0)
    }

    @Test("a stop aimed at a turn that moved on, an unsupported agent or nothing at all is refused")
    func stopRefusals() async throws {
        let f = StopFixture()
        let running = await f.session("thr-r", agent: .codex)
        let claude = await f.session("thr-c", agent: .claudeCode)
        let finished = await f.session("thr-f", agent: .codex, finished: true)
        let dispatch = f.dispatch()

        // The turn the user was looking at has been replaced.
        #expect(await dispatch.deliver(f.stop("thr-r", since: running.statusSince.addingTimeInterval(5)))
                == .refused("This task has changed"))
        // No identity at all: a stop that would hit "whatever is running now".
        #expect(await dispatch.deliver(f.stop("thr-r", since: nil))
                == .refused("A stop must name the turn it is for"))
        #expect(await dispatch.deliver(f.stop("thr-c", since: claude.statusSince))
                == .refused("Stop this on your Mac."))
        #expect(await dispatch.deliver(f.stop("thr-f", since: finished.statusSince))
                == .refused("This task has already finished."))
        #expect(await dispatch.deliver(f.stop("thr-gone", since: Date()))
                == .refused("This task is no longer on this Mac"))
        #expect(f.box.interrupted.isEmpty)
        #expect(f.box.steered == 0)
        #expect(f.box.started == 0)
        #expect(f.box.typed == 0)
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
