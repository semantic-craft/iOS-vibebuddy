import Foundation

/// Which real-time voice backend the companion uses. All three are WebSocket
/// speech-to-speech, but differ in endpoint, schema, audio sample rate, and
/// voice names — captured here so the UI and wiring stay uniform.
public enum VoiceProvider: String, CaseIterable, Sendable {
    case qwen
    case openai
    case gemini

    public var display: String {
        switch self {
        case .qwen:   return "Qwen (DashScope)"
        case .openai: return "OpenAI"
        case .gemini: return "Gemini (Google)"
        }
    }

    /// Keychain account holding this provider's API key.
    public var keychainAccount: String {
        switch self {
        case .qwen:   return "dashscope.apiKey"
        case .openai: return "openai.apiKey"
        case .gemini: return "gemini.apiKey"
        }
    }

    public var defaultModel: String {
        switch self {
        case .qwen:   return "qwen3.5-omni-plus-realtime"
        case .openai: return "gpt-realtime"
        case .gemini: return "gemini-3.1-flash-live-preview"
        }
    }

    /// Microphone capture rate the backend expects (Hz). Output is 24 kHz for all.
    public var inputSampleRate: Double {
        switch self {
        case .qwen, .gemini: return 16_000
        case .openai:        return 24_000
        }
    }

    /// A natural default voice for the conversation language. Verified voice
    /// names per provider; the user can override with a free-text Voice ID.
    public func defaultVoice(_ language: VoiceLanguage) -> String {
        switch self {
        case .qwen:   return language == .chinese ? "Tina" : "Jennifer"
        case .openai: return "marin"
        case .gemini: return language == .chinese ? "Aoede" : "Puck"
        }
    }

    public var apiKey: String? { KeychainStore.get(keychainAccount) }

    /// Where to browse this provider's available model IDs.
    public var modelsURL: URL {
        switch self {
        case .qwen:   return URL(string: "https://help.aliyun.com/zh/model-studio/realtime")!
        case .openai: return URL(string: "https://platform.openai.com/docs/models")!
        case .gemini: return URL(string: "https://ai.google.dev/gemini-api/docs/models")!
        }
    }

    /// Where to browse this provider's available voice IDs.
    public var voicesURL: URL {
        switch self {
        case .qwen:   return URL(string: "https://help.aliyun.com/zh/model-studio/realtime")!
        case .openai: return URL(string: "https://platform.openai.com/docs/guides/realtime")!
        case .gemini: return URL(string: "https://ai.google.dev/gemini-api/docs/speech-generation")!
        }
    }

    /// Where to get an API key for this provider.
    public var apiKeyURL: URL {
        switch self {
        case .qwen:   return URL(string: "https://bailian.console.aliyun.com/?apiKey=1")!
        case .openai: return URL(string: "https://platform.openai.com/api-keys")!
        case .gemini: return URL(string: "https://aistudio.google.com/apikey")!
        }
    }
}
