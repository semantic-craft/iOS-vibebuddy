import Foundation

/// One read-aloud request's settings, independent of the vendor. Qwen's region
/// and workspace ride along because they select an endpoint, not a credential.
public struct SpeechSynthesisConfiguration: Sendable, Equatable {
    public let provider: VoiceProvider
    public let model: String
    public let voice: String
    public let qwenWorkspaceID: String?
    public let qwenUseIntl: Bool
    /// The persona layered on the voice. `.standard` sends no instruction, so
    /// the request is byte-for-byte what it was before styles existed.
    public let style: VoiceStyle
    /// Which language the style instruction is written in — the summary's own,
    /// so the vendor reads it as a delivery note and not a language switch.
    public let language: VoiceLanguage

    public init(provider: VoiceProvider, model: String, voice: String,
                qwenWorkspaceID: String? = nil, qwenUseIntl: Bool = false,
                style: VoiceStyle = .standard, language: VoiceLanguage = .english) {
        self.provider = provider
        self.model = model
        self.voice = voice
        self.qwenWorkspaceID = qwenWorkspaceID
        self.qwenUseIntl = qwenUseIntl
        self.style = style
        self.language = language
    }

    /// The persona each synthesizer frames in its own vendor's words.
    var persona: VoicePersona? { style.persona(language) }
}

/// Graded so the UI can say something the user can act on without echoing a
/// provider response, which may carry credentials.
public enum SpeechSynthesisFailure: String, Error, Sendable, Equatable {
    /// The request could not even be built — a missing key, model or voice.
    case configuration
    /// The provider refused the credential (401/403) or rejected the task.
    case rejected
    case rateLimited
    /// Nothing on the wire: no network, DNS, or a refused connection.
    case unreachable
    case timedOut
    /// Reached the provider, but the exchange did not produce usable audio.
    case transport
    case emptyAudio
    case excessiveAudio

    /// English source text; the app's string tables translate it. Never
    /// includes anything the provider sent back.
    public var message: String {
        switch self {
        case .configuration: "Check the read-aloud model and voice before speaking."
        case .rejected: "The provider rejected this API key. Open its account and paste the key again."
        case .rateLimited: "The provider is rate-limiting this key. Try again in a moment."
        case .unreachable: "Could not reach the provider. Check your connection."
        case .timedOut: "The provider did not answer in time."
        case .transport: "Speech generation failed. Check your read-aloud model, voice and connection."
        case .emptyAudio: "The provider returned no audio for this text."
        case .excessiveAudio: "The provider returned more audio than a summary should need."
        }
    }
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
        /// Whether this vendor documents an instruction channel for delivery.
        /// The UI offers the style control only where it changes the audio —
        /// a picker that silently does nothing is worse than no picker.
        public let supportsStyle: Bool
        let make: @Sendable (SpeechSynthesisConfiguration) -> any SpeechSynthesizer

        init(defaultModel: String, defaultVoice: String, supportsStyle: Bool = false,
             make: @escaping @Sendable (SpeechSynthesisConfiguration) -> any SpeechSynthesizer) {
            self.defaultModel = defaultModel
            self.defaultVoice = defaultVoice
            self.supportsStyle = supportsStyle
            self.make = make
        }
    }

    /// Every provider speaks, so this is total — there is no "cannot read
    /// aloud yet" state left for callers to handle.
    public static func support(_ provider: VoiceProvider) -> Support {
        switch provider {
        case .qwen:
            return Support(defaultModel: QwenSpeechSynthesizer.defaultModel,
                           defaultVoice: QwenSpeechSynthesizer.defaultVoice,
                           supportsStyle: true) {
                QwenSpeechSynthesizer(model: $0.model, voice: $0.voice,
                                      workspaceID: $0.qwenWorkspaceID, useIntl: $0.qwenUseIntl,
                                      persona: $0.persona)
            }
        case .openai:
            // `/v1/audio/speech` does take an `instructions` field; it is left
            // unwired because this ticket asked for the three vendors below.
            return Support(defaultModel: OpenAISpeechSynthesizer.defaultModel,
                           defaultVoice: OpenAISpeechSynthesizer.defaultVoice) {
                OpenAISpeechSynthesizer(model: $0.model, voice: $0.voice)
            }
        case .gemini:
            return Support(defaultModel: GeminiSpeechSynthesizer.defaultModel,
                           defaultVoice: GeminiSpeechSynthesizer.defaultVoice,
                           supportsStyle: true) {
                GeminiSpeechSynthesizer(model: $0.model, voice: $0.voice, persona: $0.persona)
            }
        case .doubao:
            return Support(defaultModel: DoubaoSpeechSynthesizer.defaultModel,
                           defaultVoice: DoubaoSpeechSynthesizer.defaultVoice,
                           supportsStyle: true) {
                DoubaoSpeechSynthesizer(model: $0.model, voice: $0.voice, persona: $0.persona)
            }
        }
    }

    /// Whether this vendor takes a delivery instruction, as one accessor
    /// rather than four reads of `Support` — the UI, the stored setting and
    /// their tests all ask the same question, and a vendor that gains or
    /// loses a speech API should change one line here, not hunt call sites.
    public static func supportsStyle(_ provider: VoiceProvider) -> Bool {
        support(provider).supportsStyle
    }

    public static func synthesizer(_ configuration: SpeechSynthesisConfiguration) -> any SpeechSynthesizer {
        support(configuration.provider).make(configuration)
    }
}
