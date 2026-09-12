import Foundation

/// Which vendor the companion talks to. Most are WebSocket speech-to-speech
/// backends that differ in endpoint, schema, audio sample rate and voice names —
/// captured here so the UI and wiring stay uniform. One (DeepSeek) is text-only
/// and serves completion summaries alone, so a purpose asks the capability
/// flags below rather than assuming every member can do everything.
public enum VoiceProvider: String, CaseIterable, Sendable {
    case qwen
    case openai
    case gemini
    case doubao
    case deepseek

    public var supportsCompletionSummaries: Bool { self != .doubao }
    public static var summaryProviders: [Self] { allCases.filter(\.supportsCompletionSummaries) }

    /// Whether this vendor produces audio at all. Voice conversation and
    /// read-aloud both require it; a text-only vendor offers neither, and every
    /// realtime / TTS accessor below is gated on this.
    public var supportsVoice: Bool { self != .deepseek }
    public static var voiceProviders: [Self] { allCases.filter(\.supportsVoice) }

    public var display: String {
        switch self {
        case .qwen:   return "Qwen (DashScope)"
        case .openai: return "OpenAI"
        case .gemini: return "Gemini (Google)"
        case .doubao: return String(localized: "Doubao (Volcengine)", bundle: .module)
        case .deepseek: return "DeepSeek"
        }
    }

    /// Keychain account holding this provider's API key.
    public var keychainAccount: String {
        switch self {
        case .qwen:   return "dashscope.apiKey"
        case .openai: return "openai.apiKey"
        case .gemini: return "gemini.apiKey"
        case .doubao: return "doubao.realtime.apiKey"
        case .deepseek: return "deepseek.apiKey"
        }
    }

    /// The realtime conversation model. Text-only vendors have none; the voice
    /// pickers offer `voiceProviders`, so the blank is never shown.
    public var defaultModel: String {
        switch self {
        case .qwen:   return "qwen-audio-3.0-realtime-plus"
        case .openai: return "gpt-live-1"
        case .gemini: return "gemini-3.1-flash-live-preview"
        case .doubao: return "1.2.6.1"
        case .deepseek: return ""
        }
    }

    /// Microphone capture rate the backend expects (Hz). Output is 24 kHz for all.
    public var inputSampleRate: Double {
        switch self {
        case .qwen, .gemini, .doubao: return 16_000
        case .openai:        return 24_000
        // Text-only: no microphone path ever opens for it. Kept plain rather
        // than zero so a mistaken caller misconfigures instead of trapping.
        case .deepseek: return 16_000
        }
    }

    /// The voice we pick for this provider when the user has not — taste, not
    /// language. A vendor whose voices are all multilingual can still branch
    /// (Gemini), but a vendor whose pick speaks only one language does not
    /// pretend otherwise: Doubao's Vivi is Chinese, and `VoiceSettings.voice`
    /// is what swaps it for an English voice when the conversation is English.
    /// Call that, not this — this is the curated pick, not the resolved one.
    public func defaultVoice(_ language: VoiceLanguage) -> String {
        switch self {
        case .qwen:   return "longanqian"   // Qwen-Audio system voice (multilingual)
        case .openai: return "marin"
        case .gemini: return language == .chinese ? "Aoede" : "Puck"
        case .doubao: return "zh_female_vv_jupiter_bigtts"   // Chinese; English → the catalog
        case .deepseek: return ""                            // Text-only; it never speaks
        }
    }

    public var apiKey: String? { KeychainStore.get(keychainAccount) }
    /// Whether a key is stored, without reading it — see `KeychainStore.exists`.
    public var hasAPIKey: Bool { KeychainStore.exists(keychainAccount) }

    /// Where to browse this provider's available model IDs.
    public var modelsURL: URL {
        switch self {
        case .qwen:   return URL(string: "https://help.aliyun.com/zh/model-studio/qwen-audio-realtime-user-guides")!
        case .openai: return URL(string: "https://platform.openai.com/docs/models")!
        case .gemini: return URL(string: "https://ai.google.dev/gemini-api/docs/models")!
        case .doubao: return URL(string: "https://www.volcengine.com/docs/6561/2549778?lang=zh")!
        case .deepseek: return URL(string: "https://api-docs.deepseek.com/quick_start/pricing")!
        }
    }

    /// Where to browse this provider's available voice IDs.
    public var voicesURL: URL {
        switch self {
        case .qwen:   return URL(string: "https://help.aliyun.com/zh/model-studio/qwen-audio-realtime-user-guides")!
        case .openai: return URL(string: "https://developers.openai.com/api/docs/guides/live-conversations")!
        case .gemini: return URL(string: "https://ai.google.dev/gemini-api/docs/speech-generation")!
        case .doubao: return URL(string: "https://www.volcengine.com/docs/6561/2549778?lang=zh")!
        case .deepseek: return URL(string: "https://api-docs.deepseek.com/quick_start/pricing")!   // No voices; its model list
        }
    }

    /// Where to find the Bailian workspace ID (Qwen only; used for the
    /// workspace-specific `maas.aliyuncs.com` endpoint).
    public static let qwenWorkspaceIDURL = URL(string: "https://help.aliyun.com/zh/model-studio/obtain-the-app-id-and-workspace-id")!

    /// Where to get an API key for this provider.
    public var apiKeyURL: URL {
        switch self {
        case .qwen:   return URL(string: "https://bailian.console.aliyun.com/?apiKey=1")!
        case .openai: return URL(string: "https://platform.openai.com/api-keys")!
        case .gemini: return URL(string: "https://aistudio.google.com/apikey")!
        case .doubao: return URL(string: "https://console.volcengine.com/speech/new/setting/apikeys?projectName=default")!
        case .deepseek: return URL(string: "https://platform.deepseek.com/api_keys")!
        }
    }
}
