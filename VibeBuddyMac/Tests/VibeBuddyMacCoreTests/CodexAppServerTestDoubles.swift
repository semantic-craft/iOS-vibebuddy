import Foundation
import VibeBuddyKit
@testable import VibeBuddyMacCore

/// A scripted daemon connection: canned results per method, notifications and
/// server requests pushed by the test, responses recorded.
final class FakeConnection: CodexAppServerConnecting, @unchecked Sendable {
    let messages: AsyncStream<Data>
    private let sink: AsyncStream<Data>.Continuation
    private let lock = NSLock()
    private var results: [String: [String: Any]]
    private(set) var calls: [String] = []
    private(set) var responses: [(id: JSONRPCID, result: [String: Any])] = []

    init(results: [String: [String: Any]]) {
        self.results = results
        var sink: AsyncStream<Data>.Continuation!
        messages = AsyncStream(bufferingPolicy: .unbounded) { sink = $0 }
        self.sink = sink
    }

    func connect() throws {}

    func request(_ method: String, params: [String: Any], timeout: Duration) async throws -> [String: Any] {
        lock.withLock { calls.append(method) }
        if let result = lock.withLock({ results[method] }) { return result }
        throw CodexAppServerClient.ClientError.rpc(code: -32601, message: "no such method \(method)")
    }

    func notify(_ method: String, params: [String: Any]?) {}

    func respond(id: JSONRPCID, result: [String: Any]) {
        lock.withLock { responses.append((id, result)) }
    }

    func push(_ message: [String: Any]) {
        sink.yield(try! JSONSerialization.data(withJSONObject: message))
    }

    func close() { sink.finish() }

    func set(_ method: String, _ result: [String: Any]) { lock.withLock { results[method] = result } }

    /// Make a method answer with a JSON-RPC error from now on.
    func fail(_ method: String) { lock.withLock { results.removeValue(forKey: method) } }

    /// Recorded responses, newest last, as decision strings where present.
    var decisions: [String] {
        lock.withLock { responses.compactMap { $0.result["decision"] as? String } }
    }

    var lastResponse: (id: JSONRPCID, result: [String: Any])? { lock.withLock { responses.last } }
}

/// The daemon's standard hello and an empty thread list.
func fakeDaemonResults() -> [String: [String: Any]] { [
    "initialize": ["userAgent": "Codex Desktop/0.145.0 (test)"],
    "thread/list": ["data": [], "nextCursor": NSNull()],
] }

func waitFor(_ condition: @escaping () async -> Bool) async -> Bool {
    for _ in 0..<600 {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return false
}
