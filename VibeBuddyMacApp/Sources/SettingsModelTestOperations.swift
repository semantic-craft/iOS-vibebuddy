import Foundation
import VibeBuddyKit
import VibeBuddyMacCore

/// Provider adapters for explicit synthetic Settings tests. No audio or Session access.
enum SettingsModelTestOperations {
    struct VoiceConfiguration: Sendable {
        let provider: VoiceProvider
        let model: String
        let voice: String
        let workspace: String?
        let international: Bool

        var failure: String? {
            let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-".utf8)
            if model.isEmpty || !model.utf8.allSatisfy(allowed.contains) {
                return "Enter a valid realtime model ID before testing."
            }
            if voice.isEmpty { return "Enter a voice ID or use the language default." }
            if provider == .qwen, let workspace {
                let host = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-".utf8)
                if workspace.isEmpty || workspace.count > 63 || workspace.first == "-" || workspace.last == "-"
                    || !workspace.utf8.allSatisfy(host.contains) {
                    return "Check the Qwen workspace ID in Provider connection."
                }
            }
            return nil
        }

        func makeSession(apiKey: String) -> any RealtimeVoiceProvider {
            switch provider {
            case .qwen: QwenRealtimeSession(apiKey: apiKey, model: model, workspaceID: workspace, useIntl: international)
            case .openai: OpenAIVoiceSession.make(apiKey: apiKey, model: model)
            case .gemini: GeminiRealtimeSession(apiKey: apiKey, model: model)
            case .doubao: DoubaoRealtimeSession(apiKey: apiKey, model: model)
            }
        }
    }

    static func handshake(session: any RealtimeVoiceProvider, voice: String) async -> SettingsTestCoordinator.Outcome {
        guard !Task.isCancelled else { return .failure("Test cancelled.") }
        let events = await session.start(
            instructions: "This is a connection configuration check. Remain silent. No conversation, audio input or task actions are requested.",
            voice: voice, tools: [])
        // close may have raced with actor scheduling of start; close again afterward.
        guard !Task.isCancelled else { await session.close(); return .failure("Test cancelled.") }
        for await event in events {
            guard !Task.isCancelled else { break }
            switch event {
            case .connected:
                return .success(.init(message: "Realtime connection configuration confirmed. Audio and conversation were not tested."))
            case .failed:
                // Do not echo a provider response that could contain credentials.
                return .failure("Realtime connection failed. Check the API key, model, voice, region and network before retrying.")
            case .closed:
                return .failure("The connection closed before configuration was confirmed. Check the settings and retry manually.")
            default: break // Never consume audio or execute an unexpected tool call.
            }
        }
        return .failure(Task.isCancelled ? "Test cancelled." : "The connection ended without confirming configuration.")
    }

    static func summary(configuration: CompletionSummaryConfiguration, apiKey: String) async -> SettingsTestCoordinator.Outcome {
        let service = CompletionSummaryService(key: { _ in apiKey })
        let now = Date()
        let input = CompletionSummaryInput(sourceID: "settings-sample", sessionID: UUID().uuidString,
            completionID: UUID().uuidString, title: "Sample routing fix",
            finalText: "Fixed duplicate routing. Unit tests passed. Real-device verification is still pending; this result does not claim deployment or device acceptance.",
            completedAt: now, observedAt: now)
        let result = await service.generate(input, configuration: configuration)
        await service.waitUntilIdle()
        if let failure = result.failure { return .failure(summaryFailureMessage(failure)) }
        guard let text = result.text else { return .failure("The response was empty, incomplete or unsuitable for a short spoken summary.") }
        var details = [String(format: NSLocalizedString("Elapsed: %.2f s", comment: "Settings sample latency"), result.completionLatency)]
        if let usage = result.usage {
            details.append(String(format: NSLocalizedString("Tokens — input: %@, output: %@, total: %@", comment: "Settings sample token usage"),
                usage.inputTokens.map(String.init) ?? "—", usage.outputTokens.map(String.init) ?? "—", usage.totalTokens.map(String.init) ?? "—"))
        }
        return .success(.init(message: "Sample generated", text: text, details: details))
    }

    static func summaryFailureMessage(_ failure: CompletionSummaryFailure) -> String {
        switch failure {
        case .missingProvider: "Choose a completion summary provider before testing."
        case .missingModel: "Enter a text model ID to test summaries."
        case .missingKey: "Add this provider’s API key in Provider connection."
        case .invalidModel: "The text model ID contains unsupported characters."
        case .invalidWorkspace: "Check the Qwen workspace ID in Provider connection."
        case .unauthorized: "The provider rejected access. Check the key, model and region."
        case .rateLimited: "The provider rate-limited this request. No automatic retry was made."
        case .network: "Could not reach the provider. Check your connection."
        case .expired: "The 12-second deadline elapsed. No automatic retry was made."
        case .cancelled: "Test cancelled."
        case .emptyOutput, .incompleteOutput, .outputTooLong, .invalidOutput:
            "The response was empty, incomplete or unsuitable for a short spoken summary."
        case .httpError: "The provider rejected the request. Check the text model and provider configuration."
        case .invalidResponse: "The provider returned an unsupported response."
        case .disabled: "AI completion summaries are off."
        case .invalidInput, .resultTooLong: "The sample input could not be summarized."
        case .duplicate: "This completion was already handled."
        }
    }
}
