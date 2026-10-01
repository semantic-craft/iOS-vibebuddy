import Foundation
import Testing
import VibeBuddyKit
@testable import VibeBuddyMacCore

private final class CloudStreamFixture: CursorCloudStreamTransport, @unchecked Sendable {
    let handler: @Sendable (URLRequest, @escaping @Sendable (CursorCloudStreamEvent) async throws -> Void) async throws -> Void
    init(_ handler: @escaping @Sendable (URLRequest, @escaping @Sendable (CursorCloudStreamEvent) async throws -> Void) async throws -> Void) { self.handler = handler }
    func consume(_ request: URLRequest, receive: @escaping @Sendable (CursorCloudStreamEvent) async throws -> Void) async throws {
        try await handler(request, receive)
    }
}

private actor CloudReadGate {
    var waiting = false
    private var continuation: CheckedContinuation<Void, Never>?
    func block() async {
        waiting = true
        await withCheckedContinuation { continuation = $0 }
    }
    func release() { continuation?.resume(); continuation = nil }
}

private struct CloudDelayedRunTransport: CursorCloudTransport {
    let underlying: ScriptedCursorCloudTransport
    let gate: CloudReadGate
    let reads: Counter
    func cursorCloudData(for request: URLRequest) async throws -> (Data, URLResponse) {
        let response = try await underlying.cursorCloudData(for: request)
        if request.url!.path.hasSuffix("/runs/r1"), reads.next() == 0 { await gate.block() }
        return response
    }
}

@Suite("Cursor cloud stream regressions")
struct CursorCloudStreamTests {
    @Test("bounded framing handles fragmented UTF8, CRLF, multiline data and opaque IDs")
    func framing() throws {
        var parser = CursorCloudSSEParser()
        var events: [CursorCloudStreamEvent] = []
        for byte in ": keepalive\r\nevent: assistant\r\nid: opaque/汉字\r\ndata: 你好\r\ndata: world\r\n\r\nevent: status\ndata: {}\n\n".utf8 {
            if let event = try parser.append(byte) { events.append(event) }
        }
        #expect(events == [.init(id: "opaque/汉字", kind: "assistant", data: "你好\nworld"),
                           .init(id: nil, kind: "status", data: "{}")])
        var huge = CursorCloudSSEParser()
        #expect(throws: CursorCloudError.undecodable) {
            for _ in 0..<65_537 { _ = try huge.append(65) }
        }
    }

    @Test("an unreadable or still live terminal read never finishes and retries polling")
    func failedTerminalRead() async throws {
        let detail = Counter()
        // Seed ACTIVE, then switch to the idle list above.
        let seed = Counter()
        let wrapper = ScriptedCursorCloudTransport { request in
            if request.url!.path == "/v1/agents", seed.next() == 0 {
                return ScriptedCursorCloudTransport.json(#"{"items":[{"id":"bc-x","status":"ACTIVE","latestRunId":"r"}]}"#, for: request)
            }
            // Synchronous fixture callback equivalent (the public seam itself is async).
            return transportResponse(request, detail: detail)
        }
        let monitor = CursorCloudAgentMonitor(client: .init(apiKey: { "fixture" }, transport: wrapper))
        #expect(await monitor.pass(now: Date()).1.map(\.kind) == [.userPromptSubmit])
        #expect(await monitor.pass(now: Date()).1.isEmpty)
        #expect(await monitor.pass(now: Date()).1.isEmpty)
        #expect(await monitor.pass(now: Date()).1.map(\.kind) == [.stop])
        #expect(await monitor.pass(now: Date()).1.isEmpty)
    }

    @Test("cancelling an in-flight terminal read cannot claim or stop a replacement run",
          arguments: [true, false])
    func delayedTerminalCancellation(replace: Bool) async throws {
        let run = KeySlot("r1"), key = KeySlot("fixture")
        let gate = CloudReadGate()
        let underlying = ScriptedCursorCloudTransport { request in
            let path = request.url!.path
            if path.contains("/runs/") {
                let id = path.components(separatedBy: "/").last!
                return ScriptedCursorCloudTransport.json("{\"id\":\"\(id)\",\"agentId\":\"bc-x\",\"status\":\"FINISHED\"}", for: request)
            }
            if path == "/v1/agents/bc-x" { return ScriptedCursorCloudTransport.json(#"{"id":"bc-x","status":"ACTIVE"}"#, for: request) }
            return ScriptedCursorCloudTransport.json("{\"items\":[{\"id\":\"bc-x\",\"status\":\"ACTIVE\",\"latestRunId\":\"\(run.value!)\"}]}", for: request)
        }
        let stream = CloudStreamFixture { request, receive in
            let id = request.url!.path.components(separatedBy: "/").dropLast().last!
            if id == "r1" {
                try await receive(.init(id: "terminal-id", kind: "result", data: "{\"runId\":\"r1\",\"status\":\"FINISHED\"}"))
            }
            try await Task.sleep(for: .seconds(60))
        }
        let monitor = CursorCloudAgentMonitor(client: .init(apiKey: { key.value },
            transport: CloudDelayedRunTransport(underlying: underlying, gate: gate, reads: Counter()), streamTransport: stream))
        let store = SessionStore(sourceID: "fixture")
        await monitor.poll(store: store, now: Date())
        for _ in 0..<100 {
            if await gate.waiting { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await gate.waiting)
        if replace { run.value = "r2" } else { key.value = nil }
        await monitor.poll(store: store, now: Date())
        await gate.release()
        try await Task.sleep(for: .milliseconds(50))
        #expect(await store.snapshot(now: Date()).sessions.first?.status == .working)
        // Rediscover r1: the cancelled old read must not have marked it delivered.
        run.value = "r1"; key.value = "fixture"
        await monitor.poll(store: store, now: Date())
        for _ in 0..<100 {
            if await store.snapshot(now: Date()).sessions.first?.status == .done { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await store.snapshot(now: Date()).sessions.first?.status == .done)
        key.value = nil
        await monitor.poll(store: store, now: Date())
    }

    @Test("a newly discovered replacement run is started before fallback can complete it")
    func newRunOrdering() async throws {
        let run = KeySlot("r1")
        let transport = ScriptedCursorCloudTransport { request in
            if request.url!.path.contains("/runs/") {
                return ScriptedCursorCloudTransport.json("{\"id\":\"\(run.value!)\",\"agentId\":\"bc-x\",\"status\":\"FINISHED\"}", for: request)
            }
            if request.url!.path == "/v1/agents/bc-x" { return ScriptedCursorCloudTransport.json(#"{"id":"bc-x","status":"ACTIVE"}"#, for: request) }
            return ScriptedCursorCloudTransport.json("{\"items\":[{\"id\":\"bc-x\",\"status\":\"ACTIVE\",\"latestRunId\":\"\(run.value!)\"}]}", for: request)
        }
        let monitor = CursorCloudAgentMonitor(client: .init(apiKey: { "fixture" }, transport: transport))
        #expect(await monitor.pass(now: Date()).1.map(\.kind) == [.userPromptSubmit])
        run.value = "r2"
        #expect(await monitor.pass(now: Date()).1.map(\.kind) == [.userPromptSubmit])
        #expect(await monitor.pass(now: Date()).1.map(\.kind) == [.stop])
    }

    @Test("a replacement run starts without the previous cursor; key removal cancels streams")
    func replacementAndCancellation() async throws {
        let run = KeySlot("r1")
        let key = KeySlot("fixture")
        let arrivals = Counter()
        let cancellation = Counter()
        let transport = ScriptedCursorCloudTransport { request in
            if request.url!.path.contains("/runs/") {
                return ScriptedCursorCloudTransport.json("{\"id\":\"\(run.value!)\",\"agentId\":\"bc-x\",\"status\":\"RUNNING\"}", for: request)
            }
            if request.url!.path == "/v1/agents/bc-x" { return ScriptedCursorCloudTransport.json(#"{"id":"bc-x","status":"ACTIVE"}"#, for: request) }
            return ScriptedCursorCloudTransport.json("{\"items\":[{\"id\":\"bc-x\",\"status\":\"ACTIVE\",\"latestRunId\":\"\(run.value!)\"}]}", for: request)
        }
        let stream = CloudStreamFixture { request, receive in
            #expect(request.value(forHTTPHeaderField: "Last-Event-ID") == nil)
            _ = arrivals.next()
            try await receive(.init(id: "old-run-cursor", kind: "assistant", data: "{}"))
            do { try await Task.sleep(for: .seconds(60)) }
            catch { _ = cancellation.next(); throw error }
        }
        let monitor = CursorCloudAgentMonitor(client: .init(apiKey: { key.value }, transport: transport, streamTransport: stream))
        let store = SessionStore(sourceID: "fixture")
        await monitor.poll(store: store, now: Date())
        try await Task.sleep(for: .milliseconds(50))
        run.value = "r2"
        await monitor.poll(store: store, now: Date())
        try await Task.sleep(for: .milliseconds(50))
        key.value = nil
        await monitor.poll(store: store, now: Date())
        try await Task.sleep(for: .milliseconds(50))
        #expect(arrivals.next() == 2)
        #expect(cancellation.next() == 2)
    }

    @Test("reconnect uses per run cursor and 410 reads authoritative terminal once")
    func reconnectExpiry() async throws {
        let requests = Counter()
        let terminal = KeySlot(nil)
        let transport = ScriptedCursorCloudTransport { request in
            if request.url!.path.contains("/runs/") {
                let status = terminal.value ?? "RUNNING"
                return ScriptedCursorCloudTransport.json("{\"id\":\"r\",\"agentId\":\"bc-x\",\"status\":\"\(status)\",\"result\":\"done\"}", for: request)
            }
            if request.url!.path == "/v1/agents/bc-x" { return ScriptedCursorCloudTransport.json(#"{"id":"bc-x","status":"ACTIVE"}"#, for: request) }
            return ScriptedCursorCloudTransport.json(#"{"items":[{"id":"bc-x","status":"ACTIVE","latestRunId":"r"}]}"#, for: request)
        }
        let stream = CloudStreamFixture { request, receive in
            #expect(request.url!.path == "/v1/agents/bc-x/runs/r/stream")
            #expect(request.value(forHTTPHeaderField: "Accept") == "text/event-stream")
            if requests.next() == 0 {
                #expect(request.value(forHTTPHeaderField: "Last-Event-ID") == nil)
                try await receive(.init(id: "opaque:cursor", kind: "assistant", data: #"{"text":"hello"}"#))
                throw CursorCloudError.transport
            }
            #expect(request.value(forHTTPHeaderField: "Last-Event-ID") == "opaque:cursor")
            terminal.value = "FINISHED"
            throw CursorCloudError.service(status: 410, code: "stream_expired")
        }
        let monitor = CursorCloudAgentMonitor(client: .init(apiKey: { "fixture" }, transport: transport, streamTransport: stream), interval: .seconds(10))
        let store = SessionStore(sourceID: "fixture")
        let task = Task { await monitor.run(store: store) }
        defer { task.cancel() }
        for _ in 0..<100 {
            if await store.snapshot(now: Date()).sessions.first?.status == .done { break }
            try await Task.sleep(for: .milliseconds(30))
        }
        #expect(await store.snapshot(now: Date()).sessions.first?.status == .done)
        #expect(requests.next() == 2)
        let (_, events) = await monitor.pass(now: Date())
        #expect(events.isEmpty)
        task.cancel()
        await task.value
    }
}

private func transportResponse(_ request: URLRequest, detail: Counter) -> (Data, URLResponse) {
    if request.url!.path.contains("/runs/") {
        switch detail.next() {
        case 0: return ScriptedCursorCloudTransport.json("{}", status: 503, for: request)
        case 1: return ScriptedCursorCloudTransport.json(#"{"id":"r","agentId":"bc-x","status":"RUNNING"}"#, for: request)
        default: return ScriptedCursorCloudTransport.json(#"{"id":"r","agentId":"bc-x","status":"FINISHED","result":"done"}"#, for: request)
        }
    }
    if request.url!.path == "/v1/agents/bc-x" { return ScriptedCursorCloudTransport.json(#"{"id":"bc-x","status":"ACTIVE"}"#, for: request) }
    return ScriptedCursorCloudTransport.json(#"{"items":[{"id":"bc-x","status":"IDLE","latestRunId":"r"}]}"#, for: request)
}
