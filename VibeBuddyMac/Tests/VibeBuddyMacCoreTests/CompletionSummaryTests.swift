import Foundation
import Testing
import VibeBuddyKit
@testable import VibeBuddyMacCore

@Suite(.serialized)
struct CompletionSummaryTests {
    private func input(_ id: String = "completion", age: TimeInterval = 0, text: String = "Fixed duplicate routing. Unit tests passed; device verification is still pending.") -> CompletionSummaryInput {
        let now = Date()
        return .init(sourceID: "source", sessionID: "session", completionID: id, turnID: "turn",
                     title: "Routing", finalText: text, completedAt: now.addingTimeInterval(-age), observedAt: now)
    }
    private func configuration(_ provider: VoiceProvider = .qwen) -> CompletionSummaryConfiguration {
        .init(enabled: true, provider: provider, modelID: "configured-text-model", language: .chinese)
    }
    private func json(_ object: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: object) }
    private func qwen(_ text: String = "修复了重复跳转，单元测试通过；真机仍未验证。", finish: String = "stop") -> [String: Any] {
        ["choices": [["message": ["role": "assistant", "content": text], "finish_reason": finish]],
         "usage": ["prompt_tokens": 80, "completion_tokens": 22, "total_tokens": 102]]
    }
    private func session(body: Data, delay: TimeInterval = 0, status: Int = 200) -> URLSession {
        SummaryStub.state.reset(body: body, delay: delay, status: status)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SummaryStub.self]
        return URLSession(configuration: config)
    }

    @Test func officialRequestFormatsAndRegionIsolation() throws {
        for provider in VoiceProvider.summaryProviders {
            let request = try CompletionSummaryHTTP.request(input: input(), configuration: configuration(provider), key: "synthetic-key", timeout: 4)
            let bodyData = try #require(request.httpBody)
            let body = try #require(JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
            #expect(request.httpMethod == "POST")
            #expect(request.timeoutInterval == 4)
            #expect(body["model"] as? String == (provider == .gemini ? nil : "configured-text-model"))
            #expect(body["previous_response_id"] == nil && body["conversation"] == nil && body["audio"] == nil)
            if provider == .openai {
                #expect(request.url?.absoluteString == "https://api.openai.com/v1/responses")
                #expect(body["store"] as? Bool == false)
                #expect(body["tool_choice"] as? String == "none")
                #expect((body["tools"] as? [Any])?.isEmpty == true)
                #expect((body["input"] as? [Any])?.count == 1)
            } else if provider == .gemini {
                #expect(request.url?.path == "/v1beta/models/configured-text-model:generateContent")
                #expect(request.url?.query == nil)
                #expect(request.value(forHTTPHeaderField: "x-goog-api-key") == "synthetic-key")
                #expect(body["tools"] == nil)
                #expect((body["contents"] as? [Any])?.count == 1)
            } else {
                let messages = try #require(body["messages"] as? [[String: String]])
                #expect(messages.map { $0["role"] } == ["system", "user"])
                let data = try #require(messages[1]["content"]?.data(using: .utf8))
                let payload = try #require(JSONSerialization.jsonObject(with: data) as? [String: String])
                #expect(Set(payload.keys) == ["title", "finalText"])
                #expect(payload["finalText"] == input().finalText)
                #expect(body["tools"] == nil)
            }
        }
        for intl in [false, true] {
            for workspace in [nil, "workspace-123"] as [String?] {
                var c = configuration(); c.qwenUseIntl = intl; c.qwenWorkspaceID = workspace
                let request = try CompletionSummaryHTTP.request(input: input(), configuration: c, key: "synthetic", timeout: 1)
                let host = workspace.map { "\($0).\(intl ? "ap-southeast-1" : "cn-beijing").maas.aliyuncs.com" }
                    ?? (intl ? "dashscope-intl.aliyuncs.com" : "dashscope.aliyuncs.com")
                #expect(request.url?.host == host)
            }
        }
        var invalid = configuration(); invalid.qwenWorkspaceID = "other.example/path"
        #expect(invalid.configurationFailure == .invalidWorkspace)
        invalid = configuration(.gemini); invalid.modelID = "model?key=bad"
        #expect(invalid.configurationFailure == .invalidModel)
    }

    @Test func strictOfficialResponsesRetainUsageAndLimitations() throws {
        let text = "修复了重复跳转，测试通过；真机尚未验证。"
        let openai: [String: Any] = ["status": "completed", "output": [
            ["type": "reasoning", "summary": []],
            ["type": "message", "role": "assistant", "status": "completed", "content": [["type": "output_text", "text": text]]]],
            "usage": ["input_tokens": 90, "output_tokens": 25, "total_tokens": 115]]
        let gemini: [String: Any] = ["candidates": [["finishReason": "STOP", "content": ["role": "model", "parts": [
            ["thought": true, "text": "private reasoning"], ["text": text]]]]],
            "usageMetadata": ["promptTokenCount": 90, "candidatesTokenCount": 25, "totalTokenCount": 118, "thoughtsTokenCount": 3]]
        for (provider, body) in [(VoiceProvider.qwen, qwen(text)), (.openai, openai), (.gemini, gemini)] {
            let parsed = CompletionSummaryHTTP.decode(try json(body), provider: provider)
            #expect(parsed.text == text && parsed.failure == nil)
            #expect(parsed.usage?.inputTokens != nil)
        }
        for (text, failure) in [("", CompletionSummaryFailure.emptyOutput), (String(repeating: "字", count: 180) + "。", .outputTooLong),
                                ("Tests passed but", .incompleteOutput), ("**Done**.", .invalidOutput),
                                ("修复已完成。测试通过。真机未验证。", .invalidOutput),
                                ("Fixed. Tests passed. Device pending.", .invalidOutput)] {
            let parsed = CompletionSummaryHTTP.decode(try json(qwen(text)), provider: .qwen)
            #expect(parsed.text == nil && parsed.failure == failure)
            #expect(parsed.usage?.totalTokens == 102)
        }
        #expect(CompletionSummaryHTTP.decode(try json(qwen(text, finish: "length")), provider: .qwen).failure == .incompleteOutput)
        #expect(CompletionSummaryHTTP.decode(try json(qwen("Fixed v1.2, e.g. routing. Device verification is pending.")), provider: .qwen).failure == nil)
        var incomplete = openai; incomplete["status"] = "incomplete"
        #expect(CompletionSummaryHTTP.decode(try json(incomplete), provider: .openai).failure == .incompleteOutput)
        var tool = openai; tool["output"] = [["type": "function_call", "name": "approve_session"]]
        #expect(CompletionSummaryHTTP.decode(try json(tool), provider: .openai).failure == .invalidOutput)
        let partial: [String: Any] = ["candidates": [["finishReason": "MAX_TOKENS", "content": ["role": "model", "parts": [["text": text]]]]]]
        #expect(CompletionSummaryHTTP.decode(try json(partial), provider: .gemini).failure == .incompleteOutput)
    }

    @Test func configurationIsOptInAndNeverUsesRealtimeModel() throws {
        let name = "summary-tests-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("openai", forKey: VoiceSettings.providerKey)
        defaults.set("realtime-model", forKey: VoiceSettings.modelKey(.openai))
        #expect(CompletionSummaryConfiguration.load(defaults: defaults).configurationFailure == .disabled)
        defaults.set(true, forKey: CompletionSummaryConfiguration.enabledKey)
        #expect(CompletionSummaryConfiguration.load(defaults: defaults).configurationFailure == .missingModel)
        defaults.set("explicit-text", forKey: CompletionSummaryConfiguration.modelKey(.openai))
        #expect(CompletionSummaryConfiguration.load(defaults: defaults).modelID == "explicit-text")
        VoiceSettings.selectVoiceProvider(.doubao, defaults: defaults)
        defaults.set("1.2.6.1", forKey: VoiceSettings.modelKey(.doubao))
        let preserved = CompletionSummaryConfiguration.load(defaults: defaults)
        #expect(preserved.provider == .openai && preserved.modelID == "explicit-text")
        defaults.set("doubao", forKey: VoiceSettings.summaryProviderKey)
        let unsupported = CompletionSummaryConfiguration.load(defaults: defaults)
        #expect(unsupported.provider == nil && unsupported.modelID.isEmpty)
        #expect(unsupported.configurationFailure == .missingProvider)
    }

    @Test func singleRequestDuplicateAndNoPaidRetry() async throws {
        let session = session(body: try json(qwen()), delay: 0.1)
        defer { session.invalidateAndCancel() }
        let service = CompletionSummaryService(session: session, key: { _ in "synthetic" })
        let source = input()
        async let first = service.generate(source, configuration: configuration())
        async let second = service.generate(source, configuration: configuration())
        let results = await [first, second]
        #expect(results.filter { $0.failure == .duplicate }.count == 1)
        #expect(results.filter { $0.text?.contains("未验证") == true }.count == 1)
        #expect(SummaryStub.state.requestCount == 1)
        #expect(await service.generate(source, configuration: configuration()).failure == .duplicate)

        let failureSession = self.session(body: Data("private provider failure body".utf8), status: 429)
        defer { failureSession.invalidateAndCancel() }
        let failing = CompletionSummaryService(session: failureSession, key: { _ in "synthetic" })
        let result = await failing.generate(source, configuration: configuration())
        #expect(result.failure == .rateLimited && result.text == nil)
        #expect(await failing.generate(source, configuration: configuration()).failure == .duplicate)
        #expect(SummaryStub.state.requestCount == 1)
    }

    @Test func queueTimeConsumesDeadlineAndConcurrencyIsTwo() async throws {
        let session = session(body: try json(qwen()), delay: 0.5)
        defer { session.invalidateAndCancel() }
        let service = CompletionSummaryService(session: session, key: { _ in "synthetic" })
        let first = Task { await service.generate(input("1"), configuration: configuration()) }
        let second = Task { await service.generate(input("2"), configuration: configuration()) }
        for _ in 0..<100 {
            if SummaryStub.state.requestCount == 2 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(SummaryStub.state.requestCount == 2)
        let queued = await service.generate(input("3", age: 11.9), configuration: configuration())
        #expect(queued.failure == .expired)
        #expect(queued.completionLatency >= 12)
        #expect(SummaryStub.state.requestCount == 2)
        #expect(await first.value.failure == nil)
        #expect(await second.value.failure == nil)
        #expect(SummaryStub.state.maximumActive == 2)
    }

    @Test func cancellation() async throws {
        let session = session(body: try json(qwen()), delay: 1)
        defer { session.invalidateAndCancel() }
        let service = CompletionSummaryService(session: session, key: { _ in "synthetic" })
        let source = input()
        let task = Task { await service.generate(source, configuration: configuration()) }
        for _ in 0..<100 {
            if SummaryStub.state.requestCount == 1 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        task.cancel()
        #expect(await task.value.failure == .cancelled)
        #expect(await service.generate(source, configuration: configuration()).failure == .duplicate)
        #expect(SummaryStub.state.requestCount == 1)
    }

    @Test func inFlightResponseExpiresWithoutLateSuccess() async throws {
        let session = session(body: try json(qwen()), delay: 0.4)
        defer { session.invalidateAndCancel() }
        let service = CompletionSummaryService(session: session, key: { _ in "synthetic" })
        let source = input(age: 11.9)
        let result = await service.generate(source, configuration: configuration())
        #expect(result.failure == .expired && result.text == nil)
        #expect(result.completionLatency >= 12 && result.completionLatency < 12.3)
        #expect(await service.generate(source, configuration: configuration()).failure == .duplicate)
        #expect(SummaryStub.state.requestCount == 1)
    }

    @Test func gatesDoNotReadCredentialsOrSendData() async throws {
        let session = session(body: try json(qwen()))
        defer { session.invalidateAndCancel() }
        let service = CompletionSummaryService(session: session, key: { _ in
            Issue.record("Must not read a credential before input/configuration gates")
            return "synthetic"
        })
        #expect(await service.generate(input("off"), configuration: .init()).failure == .disabled)
        #expect(await service.generate(input("model"), configuration: .init(enabled: true)).failure == .missingProvider)
        #expect(await service.generate(input("doubao"), configuration: configuration(.doubao)).failure == .missingProvider)
        #expect(await service.generate(input("missing-model"), configuration: .init(enabled: true, provider: .openai)).failure == .missingModel)
        #expect(await service.generate(input("old", age: 13), configuration: configuration()).failure == .expired)
        #expect(await service.generate(input("empty", text: " \n"), configuration: configuration()).failure == .invalidInput)
        #expect(await service.generate(input("long", text: String(repeating: "a", count: 12_001)), configuration: configuration()).failure == .resultTooLong)
        #expect(SummaryStub.state.requestCount == 0)
        let noKey = CompletionSummaryService(session: session, key: { _ in nil })
        #expect(await noKey.generate(input(), configuration: configuration()).failure == .missingKey)
        #expect(SummaryStub.state.requestCount == 0)
    }
}

private final class SummaryStub: URLProtocol, @unchecked Sendable {
    static let state = State()
    private let lock = NSLock()
    private var ended = false
    private var work: DispatchWorkItem?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let plan = Self.state.started()
        let work = DispatchWorkItem { [self] in
            let deliver = lock.withLock { if ended { return false }; ended = true; return true }
            guard deliver else { return }
            Self.state.ended()
            let response = HTTPURLResponse(url: request.url!, statusCode: plan.status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: plan.body)
            client?.urlProtocolDidFinishLoading(self)
        }
        lock.withLock { self.work = work }
        DispatchQueue.global().asyncAfter(deadline: .now() + plan.delay, execute: work)
    }
    override func stopLoading() {
        let stop = lock.withLock { work?.cancel(); if ended { return false }; ended = true; return true }
        if stop { Self.state.ended() }
    }
    final class State: @unchecked Sendable {
        struct Plan { var body: Data; var delay: TimeInterval; var status: Int }
        private let lock = NSLock()
        private var plan = Plan(body: Data(), delay: 0, status: 200)
        private var count = 0, active = 0, peak = 0
        var requestCount: Int { lock.withLock { count } }
        var maximumActive: Int { lock.withLock { peak } }
        func reset(body: Data, delay: TimeInterval, status: Int) {
            lock.withLock { plan = .init(body: body, delay: delay, status: status); count = 0; active = 0; peak = 0 }
        }
        func started() -> Plan { lock.withLock { count += 1; active += 1; peak = max(peak, active); return plan } }
        func ended() { lock.withLock { active -= 1 } }
    }
}
