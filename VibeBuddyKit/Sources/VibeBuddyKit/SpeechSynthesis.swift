import Foundation

/// One read-aloud request's settings, independent of the vendor. Qwen's region
/// and workspace ride along because they select an endpoint, not a credential.
public struct SpeechSynthesisConfiguration: Sendable, Equatable {
    public let provider: VoiceProvider
    public let model: String
    public let voice: String
    public let qwenWorkspaceID: String?
    public let qwenUseIntl: Bool

    public init(provider: VoiceProvider, model: String, voice: String,
                qwenWorkspaceID: String? = nil, qwenUseIntl: Bool = false) {
        self.provider = provider
        self.model = model
        self.voice = voice
        self.qwenWorkspaceID = qwenWorkspaceID
        self.qwenUseIntl = qwenUseIntl
    }
}

/// Graded so the UI can say something the user can act on without echoing a
/// provider response, which may carry credentials.
public enum SpeechSynthesisFailure: String, Error, Sendable {
    case configuration, rejected, transport, emptyAudio, excessiveAudio
}

/// Provider-agnostic text-to-speech, shaped like `RealtimeVoiceProvider`
/// (ADR-0001): one protocol, one conformance per vendor, and a read-aloud
/// player that never learns which vendor is speaking.
public protocol SpeechSynthesizer: Sendable {
    /// One bounded request. Only the supplied text leaves the app.
    func synthesize(_ text: String, apiKey: String) async throws -> Data
}

public enum SpeechSynthesis {
    /// Everything read-aloud needs to know about a vendor, in one place so a new
    /// vendor is one case plus one Kit file.
    public struct Support: Sendable {
        public let defaultModel: String
        public let defaultVoice: String
        let make: @Sendable (SpeechSynthesisConfiguration) -> any SpeechSynthesizer
    }

    /// `nil` for a provider with no synthesis implementation yet.
    public static func support(_ provider: VoiceProvider) -> Support? {
        switch provider {
        case .qwen:
            return Support(defaultModel: QwenSpeechSynthesizer.defaultModel,
                           defaultVoice: QwenSpeechSynthesizer.defaultVoice) {
                QwenSpeechSynthesizer(model: $0.model, voice: $0.voice,
                                      workspaceID: $0.qwenWorkspaceID, useIntl: $0.qwenUseIntl)
            }
        case .openai, .gemini, .doubao:
            return nil
        }
    }

    public static func synthesizer(_ configuration: SpeechSynthesisConfiguration) -> (any SpeechSynthesizer)? {
        support(configuration.provider)?.make(configuration)
    }
}
