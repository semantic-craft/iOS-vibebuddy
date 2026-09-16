import Foundation
import Testing
import VibeBuddyKit
@testable import VibeBuddyMacCore

@Suite(.serialized)
struct PresentationDiagnosticsTests {
    @Test("Provider failure and rejected output keep their reasons and do not retry")
    func failureEvidenceAndCache() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DiagnosticProtocol.self]
        let network = URLSession(configuration: configuration)
        defer { network.invalidateAndCancel() }
        let config = CompletionSummaryConfiguration(enabled: true, provider: .qwen, modelID: "test")
        let input = CompletionSummaryInput(sourceID: "source", sessionID: "session", completionID: "round",
            title: "Task", finalText: "Verified result.", completedAt: Date(), observedAt: Date())
        for (status, content, failure) in [(429, "", CompletionSummaryFailure.rateLimited),
                                         (200, "**Invalid speech formatting**", .invalidOutput)] {
            DiagnosticProtocol.state.reset(status: status, content: content)
            let service = ContentPresentationService(session: network, key: { _ in "synthetic" })
            #expect(await service.outcome(input, purpose: .speech, configuration: config) == .failed(failure))
            #expect(await service.outcome(input, purpose: .speech, configuration: config) == .failed(failure))
            #expect(await service.generate(input, purpose: .speech, configuration: config) == nil)
            #expect(DiagnosticProtocol.state.count == 1)
        }
        DiagnosticProtocol.state.reset(status: 429, content: "")
        let store = SessionStore(sourceID: "source")
        await store.configureContentPresentation(service: .init(session: network, key: { _ in "synthetic" })) { config }
        await store.ingest(.init(kind: .userPromptSubmit, sessionID: "session", agent: .codex, timestamp: Date(), turnID: "turn"))
        await store.ingest(.init(kind: .stop, sessionID: "session", agent: .codex, timestamp: Date(), turnID: "turn",
            completionText: "Verified result.", completionSucceeded: true))
        let before = await store.snapshot(now: Date())
        let completion = try #require(before.sessions.first?.completionID)
        let response = await store.presentation(.init(sourceID: "source", target: .completion(sessionID: "session", completionID: completion)))
        #expect(response?.generated == false)
        #expect(await store.completionBody(sessionID: "session", completionID: completion).text == "Verified result.")
        #expect(await store.snapshot(now: Date()).sessions.first?.hasUnreadCompletion == true)
        #expect(DiagnosticProtocol.state.count == 1)
    }
}

private final class DiagnosticProtocol: URLProtocol, @unchecked Sendable {
    static let state = State()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (status, content) = Self.state.next()
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        let data = try! JSONSerialization.data(withJSONObject: ["choices": [[
            "message": ["role": "assistant", "content": content], "finish_reason": "stop"]]])
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
    final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var status = 200
        private var content = ""
        private var requests = 0
        var count: Int { lock.withLock { requests } }
        func reset(status: Int, content: String) {
            lock.withLock { self.status = status; self.content = content; requests = 0 }
        }
        func next() -> (Int, String) {
            lock.withLock { requests += 1; return (status, content) }
        }
    }
}
