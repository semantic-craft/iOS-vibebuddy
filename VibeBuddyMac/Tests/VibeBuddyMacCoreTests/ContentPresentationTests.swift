import Foundation
import Testing
import VibeBuddyKit
@testable import VibeBuddyMacCore

@Suite(.serialized)
struct ContentPresentationTests {
    private func configure(_ store: SessionStore, held: Bool = false) async -> URLSession {
        PresentationStub.state.reset(held: held)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [PresentationStub.self]
        let session = URLSession(configuration: config)
        await store.configureContentPresentation(service: .init(session: session, key: { _ in "synthetic" })) {
            .init(enabled: true, provider: .qwen, modelID: "test-text-model", language: .english)
        }
        return session
    }

    private func wait(_ store: SessionStore, at date: Date) async {
        await store.ingest(HookEvent(kind: .notification, sessionID: "s", agent: .codex,
            cwd: "/x/project", message: "Choose a delivery date.", waitKind: .question, timestamp: date))
    }

    private func round(_ store: SessionStore, turn: String, text: String) async {
        await store.ingest(HookEvent(kind: .userPromptSubmit, sessionID: "s", agent: .codex,
            cwd: "/x/project", timestamp: Date(), turnID: turn))
        await store.ingest(HookEvent(kind: .stop, sessionID: "s", agent: .codex,
            cwd: "/x/project", timestamp: Date(), turnID: turn,
            completionText: text, completionSucceeded: true))
    }

    @Test("another source and a replaced wait cannot produce presentations")
    func rejectsWrongSourceAndOldWait() async throws {
        let store = SessionStore(sourceID: "mac")
        let network = await configure(store)
        defer { network.invalidateAndCancel() }
        let date = Date().addingTimeInterval(-10)
        await wait(store, at: date)
        let waiting = try #require(await store.snapshot(now: date).sessions.first)
        let target = try #require(ContentPresentationTarget(session: waiting))
        #expect(await store.presentation(.init(sourceID: "other-mac", target: target)) == nil)
        await store.ingest(HookEvent(kind: .userPromptSubmit, sessionID: "s", agent: .codex,
            timestamp: date.addingTimeInterval(1), turnID: "next"))
        await wait(store, at: date.addingTimeInterval(2))
        #expect(await store.presentation(.init(sourceID: "mac", target: target)) == nil)
        #expect(PresentationStub.state.requestCount == 0)
        let current = try #require(await store.snapshot(now: date.addingTimeInterval(3)).sessions.first)
        let result = await store.presentation(.init(sourceID: "mac", target: try #require(ContentPresentationTarget(session: current))))
        #expect(result?.generated == true)
        #expect(result?.text == waiting.displayTitle + ". Choose the delivery date.")
    }

    @Test("a result arriving after the waiting task resumes is discarded")
    func rejectsInFlightStaleResult() async throws {
        let store = SessionStore(sourceID: "mac")
        let network = await configure(store, held: true)
        defer { PresentationStub.state.release(); network.invalidateAndCancel() }
        let date = Date().addingTimeInterval(-10)
        await wait(store, at: date)
        let waiting = try #require(await store.snapshot(now: date).sessions.first)
        let request = ContentPresentationRequest(sourceID: "mac", target: try #require(ContentPresentationTarget(session: waiting)))
        let task = Task { await store.presentation(request) }
        for _ in 0..<100 where PresentationStub.state.requestCount == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(PresentationStub.state.requestCount == 1)
        await store.ingest(HookEvent(kind: .userPromptSubmit, sessionID: "s", agent: .codex,
            timestamp: date.addingTimeInterval(1), turnID: "resumed"))
        PresentationStub.state.release()
        #expect(await task.value == nil)
        #expect(await store.snapshot(now: Date()).sessions.first?.status == .working)
    }

    @Test("Conflict discovered during generation rejects the same completion and duplicate cannot unlock it")
    func rejectsInFlightConflictingResult() async throws {
        let store = SessionStore(sourceID: "mac")
        let network = await configure(store, held: true)
        defer { PresentationStub.state.release(); network.invalidateAndCancel() }
        await round(store, turn: "first", text: "First verified result.")
        let session = try #require(await store.snapshot(now: Date()).sessions.first)
        let completion = try #require(session.completionID)
        let request = ContentPresentationRequest(sourceID: "mac", target: .completion(sessionID: "s", completionID: completion))
        let task = Task { await store.presentation(request) }
        for _ in 0..<100 where PresentationStub.state.requestCount == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(PresentationStub.state.requestCount == 1)
        for text in ["Conflicting result.", "First verified result."] {
            await store.ingest(.init(kind: .stop, sessionID: "s", agent: .codex, timestamp: Date(),
                turnID: "first", completionText: text, completionSucceeded: true))
        }
        PresentationStub.state.release()
        #expect(await task.value == nil)
        #expect(await store.presentation(request) == nil)
        let body = await store.completionBody(sessionID: "s", completionID: completion)
        #expect(body.text == nil)
        #expect(body.unavailableReason == "Conflicting final result evidence; ordinary reading is refused.")
        let after = await store.snapshot(now: Date())
        #expect(after.sessions.first?.completionID == completion)
        #expect(after.sessions.first?.hasUnreadCompletion == true)
        #expect(PresentationStub.state.requestCount == 1)
    }

    @Test("old recap uses its own full result and presentation never acknowledges either round")
    func oldRecapKeepsItsMaterialAndReadState() async throws {
        let store = SessionStore(sourceID: "mac")
        let network = await configure(store)
        defer { network.invalidateAndCancel() }
        await round(store, turn: "first", text: "First outcome. ORIGINAL_FIRST_DETAIL")
        let first = try #require(await store.snapshot(now: Date()).recap?.entries.first)
        await round(store, turn: "second", text: "Second outcome. ORIGINAL_SECOND_DETAIL")
        let before = await store.snapshot(now: Date())
        #expect(before.recap?.entries.count == 2)
        let result = await store.presentation(.init(sourceID: "mac", target: .recap(id: first.id), purpose: .recap))
        #expect(result?.generated == true)
        #expect(result?.text == "The first round retained its original detail.")
        let after = await store.snapshot(now: Date())
        #expect(after.sessions.first?.hasUnreadCompletion == true)
        #expect(after.recap?.entries.map(\.isRead) == [false, false])
        let presented = try #require(after.recap?.entries.first(where: { $0.id == first.id }))
        #expect(presented.contentPresentation == result)
        #expect(presented.points == first.points)
        #expect(after.recap?.horizon == before.recap?.horizon)
    }

    @Test("hook-only completion has no spoken ending, verified completion names the conversation")
    func verifiedNamedSpeech() async throws {
        let store = SessionStore(sourceID: "mac")
        let network = await configure(store)
        defer { network.invalidateAndCancel() }
        let hook = try JSONSerialization.data(withJSONObject: ["hook_event_name": "Stop", "session_id": "s",
            "cwd": "/x/Agora", "turn_id": "child-turn"])
        await store.ingest(hook, agent: .codex, receivedAt: Date())
        let child = try #require(await store.snapshot(now: Date()).sessions.first)
        let childRequest = ContentPresentationRequest(sourceID: "mac", target: try #require(ContentPresentationTarget(session: child)))
        #expect(await store.presentation(childRequest) == nil)
        #expect(PresentationStub.state.requestCount == 0)

        await round(store, turn: "main-turn", text: "Verified result.")
        await store.ingest(.init(kind: .sessionMetadataChanged, sessionID: "s", agent: .codex,
            sessionName: "Draw a harbor", timestamp: Date()))
        let main = try #require(await store.snapshot(now: Date()).sessions.first)
        let request = ContentPresentationRequest(sourceID: "mac", target: try #require(ContentPresentationTarget(session: main)))
        let result = await store.presentation(request)
        #expect(result?.generated == true)
        #expect(result?.text.hasPrefix("Draw a harbor. ") == true)
        #expect(result?.text.hasPrefix("project") == false)
    }

    @Test("Claude and Cursor wait for settled native evidence and name the conversation", arguments: [AgentKind.claudeCode, .cursor])
    func settledAgentSpeech(_ agent: AgentKind) async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("s.jsonl")
        try Data().write(to: file)
        let store = SessionStore(sourceID: "mac")
        let network = await configure(store)
        defer { network.invalidateAndCancel() }
        let start = Date().addingTimeInterval(-1), end = Date()
        let title = "Draw the evening harbor"
        await store.ingest(.init(kind: .userPromptSubmit, sessionID: "s", agent: agent,
            cwd: "/x/Agora", sessionName: title, transcriptPath: file.path,
            observationSource: .hook, timestamp: start))
        let child: [String: Any] = agent == .claudeCode
            ? ["hook_event_name": "Stop", "session_id": "s", "agent_id": "child", "last_assistant_message": "Child finished"]
            : ["hook_event_name": "subagentStop", "conversation_id": "s", "subagent_type": "Explore"]
        await store.ingest(try JSONSerialization.data(withJSONObject: child), agent: agent, receivedAt: end)
        #expect(await store.snapshot(now: end).sessions.first?.status == .working)
        #expect(await store.snapshot(now: end).sessions.first?.completionID == nil)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        func append(_ row: [String: Any]) throws {
            let handle = try FileHandle(forWritingTo: file)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: JSONSerialization.data(withJSONObject: row) + Data([10]))
        }
        if agent == .claudeCode {
            try append(["type": "assistant", "sessionId": "s", "timestamp": formatter.string(from: end),
                "message": ["stop_reason": "end_turn", "content": [["type": "text", "text": "Verified harbor result."]]]])
        } else {
            try append(["role": "assistant", "message": ["content": [["type": "text", "text": "Verified harbor result."]]]])
        }
        await store.ingest(.init(kind: .stop, sessionID: "s", agent: agent, transcriptPath: file.path,
            observationSource: .hook, timestamp: end,
            completionText: agent == .claudeCode ? "Verified harbor result." : nil, completionSucceeded: true))
        let session = try #require(await store.snapshot(now: end).sessions.first)
        let request = ContentPresentationRequest(sourceID: "mac", target: try #require(ContentPresentationTarget(session: session)))
        let pending = Task { await store.presentation(request) }
        try await Task.sleep(for: .milliseconds(50))
        #expect(PresentationStub.state.requestCount == 0)
        if agent == .claudeCode {
            try append(["type": "system", "subtype": "stop_hook_summary", "sessionId": "s",
                "timestamp": formatter.string(from: end.addingTimeInterval(0.1)),
                "preventedContinuation": false, "stopReason": "", "hookAdditionalContext": [], "hookErrors": []])
        } else { try append(["type": "turn_ended", "status": "success"]) }
        let result = await pending.value
        #expect(result?.generated == true)
        #expect(result?.text.hasPrefix(title + ". ") == true)
        #expect(result?.text.contains("unavailable") == false)
        if agent == .cursor {
            await store.noteCursorFollowupHandoff(sessionID: "s", loopCount: 0, source: .hook, at: end.addingTimeInterval(0.1))
            #expect(await store.presentation(request) == nil)
        }
        if agent == .claudeCode {
            try append(["type": "system", "subtype": "stop_hook_summary", "sessionId": "s",
                "timestamp": formatter.string(from: end.addingTimeInterval(0.2)),
                "preventedContinuation": false, "stopReason": "", "hookAdditionalContext": ["Continue working"], "hookErrors": []])
        } else {
            try append(["role": "user", "message": ["content": [["type": "text", "text": "Continue working"]]]])
        }
        #expect(await store.presentation(request) == nil)
        await store.ingest(.init(kind: .userPromptSubmit, sessionID: "s", agent: agent,
            observationSource: .hook, timestamp: end.addingTimeInterval(1)))
        #expect(await store.presentation(request) == nil)
    }

    @Test("verified completion reads a named result excerpt when the summary provider is unavailable")
    func resultExcerptWithoutProvider() async throws {
        let store = SessionStore(sourceID: "mac")
        await round(store, turn: "first", text: "The requested drawing was saved.")
        let session = try #require(await store.snapshot(now: Date()).sessions.first)
        let completionID = try #require(session.completionID)
        let result = try #require(await store.presentation(.init(sourceID: "mac",
            target: .completion(sessionID: "s", completionID: completionID), purpose: .speech)))
        #expect(result.generated == false)
        #expect(result.text.contains(session.displayTitle))
        #expect(result.text.contains("The requested drawing was saved."))
        #expect(!result.text.contains("unavailable") && !result.text.contains("摘要暂时不可用"))
    }

    @Test("legacy recap without original material degrades without borrowing the newer result")
    func legacyRecapWithoutMaterial() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("content-presentation-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let date = Date().addingTimeInterval(-20)
        let oldID = RecapEntry.completedID(sourceID: "mac", sessionID: "s", completionID: "legacy")
        let old = RecapLedger.Stored(id: oldID, kind: .completed, sessionID: "s", completionID: "legacy",
            agent: .codex, project: "project", title: "Old round", fallbackSummary: "Saved legacy summary.",
            ledgerLine: nil, endedAt: date, recordedAt: date, isRead: false)
        try JSONEncoder().encode(RecapLedger.File(horizon: nil, entries: [oldID: old]))
            .write(to: dir.appendingPathComponent("recap-ledger.json"))
        let store = SessionStore(sourceID: "mac", journalURL: dir.appendingPathComponent("lifecycle-journal.json"))
        let network = await configure(store)
        defer { network.invalidateAndCancel() }
        await round(store, turn: "new", text: "Second outcome. ORIGINAL_SECOND_DETAIL")
        let result = await store.presentation(.init(sourceID: "mac", target: .recap(id: oldID), purpose: .recap))
        #expect(result?.generated == false)
        #expect(result?.text.isEmpty == false)
        #expect(PresentationStub.state.requestCount == 0)
        let snapshot = await store.snapshot(now: Date())
        #expect(snapshot.recap?.entries.first(where: { $0.id == oldID })?.points == ["Saved legacy summary."])
        #expect(snapshot.sessions.first?.hasUnreadCompletion == true)
    }
}

private final class PresentationStub: URLProtocol, @unchecked Sendable {
    static let state = State()
    private let lock = NSLock()
    private var ended = false
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { if !Self.state.started(self) { respond() } }
    override func stopLoading() { lock.withLock { ended = true } }

    func respond() {
        guard lock.withLock({ if ended { return false }; ended = true; return true }) else { return }
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var bytes = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = stream.read(&bytes, maxLength: bytes.count)
                guard count > 0 else { break }
                body.append(contentsOf: bytes.prefix(count))
            }
        }
        let material = String(decoding: body, as: UTF8.self)
        let text = material.contains("ORIGINAL_FIRST_DETAIL")
            ? "The first round retained its original detail."
            : material.contains("ORIGINAL_SECOND_DETAIL") ? "The second round has different material." : "Choose the delivery date."
        let data = try! JSONSerialization.data(withJSONObject: ["choices": [[
            "message": ["role": "assistant", "content": text], "finish_reason": "stop"]]])
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var held = false
        private var count = 0
        private var pending: [PresentationStub] = []
        var requestCount: Int { lock.withLock { count } }
        func reset(held: Bool) { lock.withLock { self.held = held; count = 0; pending = [] } }
        func started(_ request: PresentationStub) -> Bool {
            lock.withLock { count += 1; if held { pending.append(request) }; return held }
        }
        func release() {
            let requests = lock.withLock { let result = pending; pending = []; held = false; return result }
            for request in requests { request.respond() }
        }
    }
}
