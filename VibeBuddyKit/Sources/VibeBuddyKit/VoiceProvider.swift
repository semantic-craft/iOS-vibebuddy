import Foundation

/// Which vendor the companion talks to. Most are WebSocket speech-to-speech
/// backends that differ in endpoint, schema, audio sample rate and voice names —
/// captured here so the UI and wiring stay uniform. One (DeepSeek) is text-only
/// and serves completion summaries alone, so a purpose asks the capability
/// flags below rather than assuming every member can do everything.
public enum VoiceProvider: String, CaseIterable, Sendable {
    case qwen
    case openai
    case doubao
    case deepseek
    case minimax
    case gemini

    public var supportsCompletionSummaries: Bool { self != .doubao }
    public static var summaryProviders: [Self] { allCases.filter(\.supportsCompletionSummaries) }

    /// Whether this integration supports realtime conversation. MiniMax has
    /// text and TTS adapters only; read-aloud has its own capability list.
    public var supportsVoice: Bool { self != .deepseek && self != .minimax }
    public static var voiceProviders: [Self] { allCases.filter(\.supportsVoice) }

    public static var readAloudProviders: [Self] { allCases.filter { SpeechSynthesis.support($0) != nil } }

    public var display: String {
        switch self {
        case .qwen:   return "Qwen (DashScope)"
        case .openai: return "OpenAI"
        case .doubao: return String(localized: "Doubao (Volcengine)", bundle: .module)
        case .deepseek: return "DeepSeek"
        case .minimax: return "MiniMax"
        case .gemini: return "Gemini"
        }
    }

    /// Keychain account holding this provider's API key.
    public var keychainAccount: String {
        switch self {
        case .qwen:   return "dashscope.apiKey"
        case .openai: return "openai.apiKey"
        case .doubao: return "doubao.realtime.apiKey"
        case .deepseek: return "deepseek.apiKey"
        case .minimax: return "minimax.apiKey"
        case .gemini: return "gemini.apiKey"
        }
    }

    /// The realtime conversation model. Text-only vendors have none; the voice
    /// pickers offer `voiceProviders`, so the blank is never shown.
    public var defaultModel: String {
        switch self {
        case .qwen:   return "qwen-audio-3.0-realtime-plus"
        case .openai: return "gpt-live-1"
        case .doubao: return "1.2.6.1"
        case .gemini: return "gemini-3.8-live"
        case .deepseek, .minimax: return ""
        }
    }

    /// Microphone capture rate the backend expects (Hz). Output is 24 kHz for all.
    public var inputSampleRate: Double {
        switch self {
        case .qwen, .doubao, .gemini: return 16_000
        case .openai:        return 24_000
        // No realtime adapter: no microphone path opens for this vendor. Kept plain rather
        // than zero so a mistaken caller misconfigures instead of trapping.
        case .deepseek, .minimax: return 16_000
        }
    }

    /// The voice we pick for this provider when the user has not — taste, not
    /// language. A vendor whose pick speaks only one language does not
    /// pretend otherwise: Doubao's Vivi is Chinese, and `VoiceSettings.voice`
    /// is what swaps it for an English voice when the conversation is English.
    /// Call that, not this — this is the curated pick, not the resolved one.
    public func defaultVoice(_ language: VoiceLanguage) -> String {
        switch self {
        case .qwen:   return "longanqian"   // Qwen-Audio system voice (multilingual)
        case .openai: return "marin"
        case .doubao: return "zh_female_vv_jupiter_bigtts"   // Chinese; English → the catalog
        case .gemini: return "Kore"
        case .deepseek, .minimax: return ""                            // No realtime conversation voice
        }
    }

    public var apiKey: String? {
        if let name = acceptanceKeyName, E2ERunConfiguration.current != nil {
            return ProcessInfo.processInfo.environment[name]
        }
        return KeychainStore.get(keychainAccount)
    }
    /// Whether a key is stored, without reading it — see `KeychainStore.exists`.
    public var hasAPIKey: Bool {
        if let name = acceptanceKeyName, E2ERunConfiguration.current != nil {
            return !(ProcessInfo.processInfo.environment[name] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return KeychainStore.exists(keychainAccount)
    }

    /// Explicit isolated acceptance only; ordinary apps keep their saved keys.
    public var acceptanceKeyName: String? {
        switch self {
        case .gemini: "GEMINI_API_KEY"
        case .minimax: "MINIMAX_API_KEY"
        default: nil
        }
    }

    /// Where to browse this provider's available model IDs.
    public var modelsURL: URL {
        switch self {
        case .qwen:   return URL(string: "https://help.aliyun.com/zh/model-studio/qwen-audio-realtime-user-guides")!
        case .openai: return URL(string: "https://platform.openai.com/docs/models")!
        case .doubao: return URL(string: "https://www.volcengine.com/docs/6561/2549778?lang=zh")!
        case .minimax: return URL(string: "https://platform.minimax.cn/docs/api-reference/text-chat-openai")!
        case .gemini: return URL(string: "https://ai.google.dev/gemini-api/docs/models")!
        case .deepseek: return URL(string: "https://api-docs.deepseek.com/quick_start/pricing")!
        }
    }

    public enum ModelPurpose: Sendable {
        case conversation
        case text
        case speechSynthesis
    }

    public func modelDocumentationURL(for purpose: ModelPurpose, model: String? = nil) -> URL? {
        let address: String
        switch (self, purpose) {
        case (.qwen, .conversation):
            address = "https://help.aliyun.com/zh/model-studio/qwen-audio-realtime-user-guides"
        case (.qwen, .text):
            address = "https://help.aliyun.com/zh/model-studio/text-generation"
        case (.qwen, .speechSynthesis):
            address = "https://help.aliyun.com/zh/model-studio/non-realtime-tts-user-guide"
        case (.openai, .conversation):
            address = OpenAIVoiceSession.usesLive(model ?? defaultModel)
                ? "https://developers.openai.com/api/docs/guides/live-conversations"
                : "https://developers.openai.com/api/docs/guides/realtime"
        case (.openai, .text):
            address = "https://developers.openai.com/api/docs/models"
        case (.openai, .speechSynthesis):
            address = "https://developers.openai.com/api/docs/guides/text-to-speech"
        case (.doubao, .conversation):
            address = "https://www.volcengine.com/docs/6561/2549778?lang=zh"
        case (.doubao, .speechSynthesis):
            address = "https://www.volcengine.com/docs/6561/1598757?lang=zh"
        case (.minimax, .text):
            address = "https://platform.minimax.cn/docs/api-reference/text-chat-openai"
        case (.minimax, .speechSynthesis):
            address = "https://platform.minimax.cn/docs/api-reference/speech-t2a-http"
        case (.gemini, .conversation):
            address = "https://ai.google.dev/gemini-api/docs/live-api"
        case (.gemini, .speechSynthesis):
            address = "https://ai.google.dev/gemini-api/docs/speech-generation"
        case (.minimax, .conversation): return nil
        case (.gemini, .text):
            address = "https://ai.google.dev/gemini-api/docs/text-generation"
        case (.deepseek, .text):
            address = "https://api-docs.deepseek.com/quick_start/pricing/"
        case (.doubao, .text), (.deepseek, .conversation), (.deepseek, .speechSynthesis):
            return nil
        }
        return URL(string: address)
    }

    /// Where to browse this provider's available voice IDs.
    public var voicesURL: URL {
        switch self {
        case .qwen:   return URL(string: "https://help.aliyun.com/zh/model-studio/qwen-audio-realtime-user-guides")!
        case .openai: return URL(string: "https://developers.openai.com/api/docs/guides/live-conversations")!
        case .doubao: return URL(string: "https://www.volcengine.com/docs/6561/2549778?lang=zh")!
        case .minimax: return URL(string: "https://platform.minimax.cn/docs/faq/system-voice-id")!
        case .gemini: return URL(string: "https://ai.google.dev/gemini-api/docs/speech-generation")!
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
        case .doubao: return URL(string: "https://console.volcengine.com/speech/new/setting/apikeys?projectName=default")!
        case .minimax: return URL(string: "https://platform.minimax.cn/console/plan")!
        case .gemini: return URL(string: "https://aistudio.google.com/api-keys")!
        case .deepseek: return URL(string: "https://platform.deepseek.com/api_keys")!
        }
    }
}
