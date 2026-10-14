import Foundation
import VibeBuddyKit

/// Summary-specific validation around the reusable, text-only local transport.
struct GeminiCLI: Sendable {
    typealias Runner = AntigravityTextRunner.Runner
    var runner = AntigravityTextRunner()
    var run: Runner {
        get { runner.run }
        set { runner.run = newValue }
    }
    func generate(input: CompletionSummaryInput, configuration: CompletionSummaryConfiguration,
                  timeout: TimeInterval, purpose: SummaryPurpose) async -> CompletionSummaryResponse {
        guard input.title.count + input.finalText.count <= 50_000 else { return .init(failure: .resultTooLong) }
        do {
            let evidence = try JSONSerialization.data(withJSONObject: ["title": input.title, "finalText": input.finalText])
            let prompt = CompletionSummaryHTTP.instructions(style: configuration.contentStyle, purpose: purpose,
                language: configuration.language, voiceStyle: configuration.speechStyle) + "\n" + String(decoding: evidence, as: UTF8.self)
            let reply = await runner.generate(text: prompt, timeout: timeout)
            if let failure = reply.failure {
                return .init(failure: CompletionSummaryFailure(rawValue: failure.rawValue) ?? .invalidResponse)
            }
            guard let text = reply.text else { return .init(failure: .invalidResponse) }
            let wrapped: [String: Any] = ["choices": [["finish_reason": "stop", "message": ["role": "assistant", "content": text]]]]
            let decoded = CompletionSummaryHTTP.decode(try JSONSerialization.data(withJSONObject: wrapped), provider: .gemini, purpose: purpose)
            return .init(text: decoded.text, usage: .init(inputTokens: reply.inputTokens, outputTokens: reply.outputTokens,
                totalTokens: reply.totalTokens, reasoningTokens: reply.thinkingTokens), failure: decoded.failure)
        } catch { return .init(failure: .invalidResponse) }
    }
}
