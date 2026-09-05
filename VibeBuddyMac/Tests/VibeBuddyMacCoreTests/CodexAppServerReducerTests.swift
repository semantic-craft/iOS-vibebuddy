import Foundation
import Testing
import VibeBuddyKit
@testable import VibeBuddyMacCore

/// Fixtures follow the app-server v2 schema (`codex app-server
/// generate-json-schema`, CLI 0.152) and the shapes a real daemon returned to
/// the 2026-09-05 read-only probe.
@Suite("Codex app-server reducer")
struct CodexAppServerReducerTests {
    let now = Date(timeIntervalSince1970: 1_788_600_000)

    private func json(_ text: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:]
    }

    private func thread(id: String = "thr-1", status: String, flags: [String] = [],
                        source: String = "\"vscode\"", cwd: String = "/x/project") -> [String: Any] {
        let statusJSON = status == "active"
            ? #"{"type":"active","activeFlags":[\#(flags.map { "\"\($0)\"" }.joined(separator: ","))]}"#
            : #"{"type":"\#(status)"}"#
        return json(#"{"id":"\#(id)","sessionId":"\#(id)","cwd":"\#(cwd)","source":\#(source),"status":\#(statusJSON),"#
                    + #""gitInfo":{"branch":"main","sha":"abc"},"cliVersion":"0.153.3","name":"Clean plugin dir","turns":[]}"#)
    }

    @Test("a loaded active Desktop thread surfaces as working with its cwd, branch and thread id")
    func seedActive() {
        var reducer = CodexAppServerReducer()
        let events = reducer.seed(thread: thread(status: "active"), receivedAt: now)
        #expect(events.map(\.kind) == [.userPromptSubmit])
        let event = events[0]
        #expect(event.sessionID == "thr-1")
        #expect(event.agent == .codex)
        #expect(event.cwd == "/x/project")
        #expect(event.observationSource == .appserver)
        #expect(event.desktopThreadID == "thr-1")
        #expect(event.enrichment?.branch == "main")
    }

    @Test("active flags map to a permission or question wait")
    func seedWaiting() {
        var reducer = CodexAppServerReducer()
        let approval = reducer.seed(thread: thread(status: "active", flags: ["waitingOnApproval"]), receivedAt: now)
        #expect(approval.map(\.kind) == [.userPromptSubmit, .notification])
        #expect(approval[1].message == "Permission required")
        let question = reducer.seed(thread: thread(id: "thr-2", status: "active", flags: ["waitingOnUserInput"]), receivedAt: now)
        #expect(question[1].message == "Waiting for your input")
    }

    @Test("idle is done, systemError is a failed stop, notLoaded and subagent threads surface nothing")
    func seedOtherStates() {
        var reducer = CodexAppServerReducer()
        #expect(reducer.seed(thread: thread(status: "idle"), receivedAt: now).map(\.kind) == [.sessionStart])
        let failed = reducer.seed(thread: thread(id: "thr-e", status: "systemError"), receivedAt: now)
        #expect(failed.map(\.kind) == [.stop])
        #expect(FailureHeuristic.looksFailed(failed[0].message))
        #expect(reducer.seed(thread: thread(id: "thr-n", status: "notLoaded"), receivedAt: now).isEmpty)
        #expect(reducer.threads["thr-n"]?.loaded == false)
        let sub = thread(id: "thr-s", status: "active", source: #"{"subAgent":{"parent":"thr-1"}}"#)
        #expect(reducer.seed(thread: sub, receivedAt: now).isEmpty)
        #expect(reducer.threads["thr-s"] == nil)
    }

    @Test("a CLI thread carries no desktop thread id")
    func cliThread() {
        var reducer = CodexAppServerReducer()
        let events = reducer.seed(thread: thread(status: "active", source: "\"cli\""), receivedAt: now)
        #expect(events[0].desktopThreadID == nil)
    }

    @Test("turn, item and token notifications become the reducer's own events")
    func turnLifecycle() {
        var reducer = CodexAppServerReducer()
        _ = reducer.seed(thread: thread(status: "idle"), receivedAt: now)

        let started = reducer.handle(json(#"{"method":"turn/started","params":{"threadId":"thr-1","turn":{"id":"turn-1","items":[],"status":"inProgress"}}}"#), receivedAt: now)
        #expect(started.map(\.kind) == [.userPromptSubmit])
        #expect(started[0].turnID == "turn-1")
        #expect(started[0].cwd == "/x/project")

        let call = reducer.handle(json(#"{"method":"item/started","params":{"threadId":"thr-1","turnId":"turn-1","startedAtMs":1,"item":{"type":"commandExecution","id":"i1","command":"npm test","cwd":"/x/project","status":"inProgress"}}}"#), receivedAt: now)
        #expect(call.map(\.kind) == [.preToolUse])
        #expect(call[0].toolName == "Shell")

        let failed = reducer.handle(json(#"{"method":"item/completed","params":{"threadId":"thr-1","turnId":"turn-1","completedAtMs":2,"item":{"type":"commandExecution","id":"i1","command":"npm test","cwd":"/x/project","status":"failed","exitCode":1}}}"#), receivedAt: now)
        #expect(failed.map(\.kind) == [.postToolUse])
        #expect(failed[0].toolError == true)

        let mcp = reducer.handle(json(#"{"method":"item/started","params":{"threadId":"thr-1","turnId":"turn-1","startedAtMs":3,"item":{"type":"mcpToolCall","id":"i2","server":"docs","tool":"search","status":"inProgress"}}}"#), receivedAt: now)
        #expect(mcp[0].toolName == "docs/search")

        // Reasoning and agent prose are not tools.
        let prose = reducer.handle(json(#"{"method":"item/started","params":{"threadId":"thr-1","turnId":"turn-1","startedAtMs":4,"item":{"type":"agentMessage","id":"i3","text":"Working on it"}}}"#), receivedAt: now)
        #expect(prose.isEmpty)

        let usage = reducer.handle(json(#"{"method":"thread/tokenUsage/updated","params":{"threadId":"thr-1","turnId":"turn-1","tokenUsage":{"last":{"inputTokens":9000,"cachedInputTokens":8000,"outputTokens":800,"reasoningOutputTokens":300,"totalTokens":9800},"total":{"inputTokens":90000,"cachedInputTokens":80000,"outputTokens":8000,"reasoningOutputTokens":3000,"totalTokens":98000},"modelContextWindow":272000}}}"#), receivedAt: now)
        #expect(usage.map(\.kind) == [.sessionMetadataChanged])
        #expect(usage[0].enrichment?.tokens == 9800)
        #expect(usage[0].enrichment?.contextTokens == 9500)
        #expect(usage[0].enrichment?.contextWindow == 272000)

        let completed = reducer.handle(json(#"{"method":"turn/completed","params":{"threadId":"thr-1","turn":{"id":"turn-1","status":"completed","items":[{"type":"agentMessage","id":"i9","text":"All green.\n"}]}}}"#), receivedAt: now)
        #expect(completed.map(\.kind) == [.stop])
        #expect(completed[0].message == "All green.")
        #expect(completed[0].turnID == "turn-1")
    }

    @Test("a failed or interrupted turn stops with a failure-looking message")
    func turnFailure() {
        var reducer = CodexAppServerReducer()
        _ = reducer.seed(thread: thread(status: "active"), receivedAt: now)
        let failed = reducer.handle(json(#"{"method":"turn/completed","params":{"threadId":"thr-1","turn":{"id":"t","status":"failed","items":[],"error":{"message":"rate limited"}}}}"#), receivedAt: now)
        #expect(failed[0].message == "Turn failed: rate limited")
        #expect(FailureHeuristic.looksFailed(failed[0].message))
        let interrupted = reducer.handle(json(#"{"method":"turn/completed","params":{"threadId":"thr-1","turn":{"id":"t2","status":"interrupted","items":[]}}}"#), receivedAt: now)
        #expect(interrupted[0].message == "Turn interrupted")
    }

    @Test("status changes for a thread seen only by id still move it, and closing unloads it silently")
    func statusChangedAndClosed() {
        var reducer = CodexAppServerReducer()
        let active = reducer.handle(json(#"{"method":"thread/status/changed","params":{"threadId":"thr-9","status":{"type":"active","activeFlags":["waitingOnApproval"]}}}"#), receivedAt: now)
        #expect(active.map(\.kind) == [.userPromptSubmit, .notification])
        #expect(reducer.threads["thr-9"]?.loaded == true)
        let idle = reducer.handle(json(#"{"method":"thread/status/changed","params":{"threadId":"thr-9","status":{"type":"idle"}}}"#), receivedAt: now)
        #expect(idle.map(\.kind) == [.sessionStart])
        let closed = reducer.handle(json(#"{"method":"thread/closed","params":{"threadId":"thr-9"}}"#), receivedAt: now)
        #expect(closed.isEmpty)
        #expect(reducer.threads["thr-9"]?.loaded == false)
        let unloaded = reducer.handle(json(#"{"method":"thread/status/changed","params":{"threadId":"thr-9","status":{"type":"notLoaded"}}}"#), receivedAt: now)
        #expect(unloaded.isEmpty)
    }

    @Test("a deleted or archived thread ends its session; an unknown one is ignored")
    func deletedThread() {
        var reducer = CodexAppServerReducer()
        _ = reducer.seed(thread: thread(status: "idle"), receivedAt: now)
        let deleted = reducer.handle(json(#"{"method":"thread/deleted","params":{"threadId":"thr-1"}}"#), receivedAt: now)
        #expect(deleted.map(\.kind) == [.sessionEnd])
        #expect(reducer.threads["thr-1"] == nil)
        #expect(reducer.handle(json(#"{"method":"thread/archived","params":{"threadId":"thr-x"}}"#), receivedAt: now).isEmpty)
    }

    @Test("thread/started seeds the thread; server-initiated requests are recognized and produce nothing")
    func threadStartedAndServerRequests() {
        var reducer = CodexAppServerReducer()
        let started = reducer.handle(["method": "thread/started", "params": ["thread": thread(status: "idle")]], receivedAt: now)
        #expect(started.map(\.kind) == [.sessionStart])
        let request = json(#"{"id":7,"method":"item/commandExecution/requestApproval","params":{"threadId":"thr-1","turnId":"t","itemId":"i","reason":"needs network"}}"#)
        #expect(CodexAppServerReducer.serverRequestMethod(request) == "item/commandExecution/requestApproval")
        #expect(reducer.handle(request, receivedAt: now).isEmpty)
        #expect(CodexAppServerReducer.serverRequestMethod(json(#"{"method":"turn/started","params":{}}"#)) == nil)
    }

    @Test("an error the daemon will not retry is a failed stop; a retried one is noise")
    func errorNotification() {
        var reducer = CodexAppServerReducer()
        _ = reducer.seed(thread: thread(status: "active"), receivedAt: now)
        let retried = reducer.handle(json(#"{"method":"error","params":{"threadId":"thr-1","turnId":"t","willRetry":true,"error":{"message":"overloaded"}}}"#), receivedAt: now)
        #expect(retried.isEmpty)
        let final = reducer.handle(json(#"{"method":"error","params":{"threadId":"thr-1","turnId":"t","willRetry":false,"error":{"message":"quota exhausted"}}}"#), receivedAt: now)
        #expect(final.map(\.kind) == [.stop])
        #expect(final[0].message == "Error: quota exhausted")
    }
}

@Suite("Codex app-server client framing")
struct CodexAppServerClientFramingTests {
    @Test("a masked client frame round-trips through the frame parser")
    func maskedRoundTrip() {
        for size in [0, 5, 126, 300, 70_000] {
            let payload = Data((0..<size).map { UInt8($0 & 0xFF) })
            let frame = CodexAppServerClient.frame(opcode: 0x1, payload: payload)
            let parsed = CodexAppServerClient.parseFrame(frame)
            #expect(parsed?.fin == true)
            #expect(parsed?.opcode == 0x1)
            #expect(parsed?.payload == payload)
            #expect(parsed?.consumed == frame.count)
        }
    }

    @Test("an unmasked server frame parses, and a partial one waits for more bytes")
    func serverFrame() {
        let text = Data(#"{"method":"turn/started"}"#.utf8)
        var frame = Data([0x81, UInt8(text.count)])
        frame.append(text)
        let parsed = CodexAppServerClient.parseFrame(frame)
        #expect(parsed?.payload == text)
        #expect(CodexAppServerClient.parseFrame(frame.prefix(10)) == nil)
    }
}

@Suite("Codex app-server authority in the store")
struct CodexAppServerAuthorityTests {
    let now = Date(timeIntervalSince1970: 1_788_600_000)

    private func event(_ kind: HookEvent.Kind, source: ObservationSource, at: Date,
                       message: String? = nil, probeRetirement: Bool = false) -> HookEvent {
        HookEvent(kind: kind, sessionID: "thr-1", agent: .codex, cwd: "/x/project",
                  message: message, observationSource: source, timestamp: at,
                  probeRetirement: probeRetirement)
    }

    @Test("a fresh app-server report outranks a rollout stop for the same thread")
    func rolloutCannotRetireDaemonThread() async {
        let store = SessionStore()
        await store.ingest(event(.userPromptSubmit, source: .appserver, at: now))
        // The rollout tailer's ownerless probe would retire the thread.
        await store.ingest(event(.stop, source: .rollout, at: now.addingTimeInterval(30),
                                 message: "Abandoned", probeRetirement: true))
        let session = await store.snapshot(now: now.addingTimeInterval(31)).sessions.first { $0.id == "thr-1" }
        #expect(session?.status == .working)
        #expect(session?.observations?.map(\.source) == [.appserver, .rollout])
    }

    @Test("once the app-server evidence is stale, rollout events move the thread again")
    func staleDaemonYields() async {
        let store = SessionStore()
        await store.ingest(event(.userPromptSubmit, source: .appserver, at: now))
        let later = now.addingTimeInterval(SessionStore.appServerAuthorityWindow + 1)
        await store.ingest(event(.stop, source: .rollout, at: later, message: "Done"))
        let session = await store.snapshot(now: later).sessions.first { $0.id == "thr-1" }
        #expect(session?.status == .done)
    }

    @Test("a hook SessionEnd still removes a daemon-reported thread")
    func sessionEndPasses() async {
        let store = SessionStore()
        await store.ingest(event(.userPromptSubmit, source: .appserver, at: now))
        await store.ingest(event(.sessionEnd, source: .hook, at: now.addingTimeInterval(1)))
        let sessions = await store.snapshot(now: now.addingTimeInterval(2)).sessions
        #expect(!sessions.contains { $0.id == "thr-1" })
    }
}

/// Opt-in end-to-end check against the daemon on this machine. Read-only:
/// initialize, list, and disconnect.
@Suite("Codex app-server live socket", .enabled(if: ProcessInfo.processInfo.environment["VIBEBUDDY_CODEX_SOCKET_TEST"] == "1"))
struct CodexAppServerLiveTests {
    @Test("initialize and thread/list succeed over the control socket")
    func initializeAndList() async throws {
        let client = CodexAppServerClient()
        try client.connect()
        defer { client.close() }
        let hello = try await client.request("initialize", params: [
            "clientInfo": ["name": "vibebuddy-test", "version": "0"], "capabilities": [:],
        ])
        #expect((hello["userAgent"] as? String)?.isEmpty == false)
        client.notify("initialized")
        let page = try await client.request("thread/list", params: ["limit": 2])
        #expect(page["data"] is [Any])
    }
}
