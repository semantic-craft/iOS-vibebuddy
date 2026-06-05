import Foundation
import Security

/// Minimal Keychain wrapper for the one secret we hold: the user's own DashScope
/// API key. Never written to UserDefaults or committed; read at runtime only.
/// Shared by iOS and Mac.
public enum KeychainStore {
    private static let service = "com.vibebuddy.secrets"

    public static func set(_ value: String?, for key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
        guard let value, !value.isEmpty, let data = value.data(using: .utf8) else { return }
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }

    public static func get(_ key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data, let s = String(data: data, encoding: .utf8)
        else { return nil }
        return s
    }
}

/// The language the voice companion converses in — drives speech recognition,
/// the model's reply language, and the spoken voice. Independent of the app's UI
/// language (which is English).
public enum VoiceLanguage: String, CaseIterable, Sendable {
    case english = "en"
    case chinese = "zh"

    /// BCP-47 locale for `SFSpeechRecognizer` and `AVSpeechSynthesisVoice`.
    public var bcp47: String {
        switch self {
        case .english: return "en-US"
        case .chinese: return "zh-CN"
        }
    }

    /// One line appended to the system prompt to pin the reply language.
    public var replyInstruction: String {
        switch self {
        case .english: return "Always reply in English."
        case .chinese: return "Always reply in Chinese (简体中文)."
        }
    }

    /// `language_type` value for the Qwen TTS API.
    public var qwenTTSLanguage: String {
        switch self {
        case .english: return "English"
        case .chinese: return "Chinese"
        }
    }
}

/// Names + accessors for the voice companion's settings. The API key lives in the
/// Keychain (user-provided, BYO); the rest are plain UserDefaults values. The
/// companion is available whenever a key is present — no separate enable toggle.
public enum VoiceSettings {
    public static let apiKeyKeychain = "dashscope.apiKey"
    public static let modelKey = "voiceModel"
    public static let regionIntlKey = "voiceRegionIntl"
    public static let conversationLanguageKey = "voiceConversationLanguage"
    public static let realtimeVoiceKey = "voiceRealtimeVoice"
    public static let qwenRealtimeModelKey = "voiceQwenRealtimeModel"

    public static let qwenRealtimeModelDefault = "qwen3.5-omni-plus-realtime"

    public static var apiKey: String? { KeychainStore.get(apiKeyKeychain) }
    public static var model: String { UserDefaults.standard.string(forKey: modelKey) ?? "qwen-plus" }
    /// China (Beijing) endpoint by default; toggle for the international site.
    public static var useIntl: Bool { UserDefaults.standard.bool(forKey: regionIntlKey) }
    /// Conversation language; English by default to match the app UI.
    public static var conversationLanguage: VoiceLanguage {
        VoiceLanguage(rawValue: UserDefaults.standard.string(forKey: conversationLanguageKey) ?? "")
            ?? .english
    }
    /// The qwen3.5-omni-realtime speaking voice ID, user-editable. When blank it
    /// follows the conversation language: an English-native voice for English,
    /// a warm Chinese voice for 中文 (CN voices carry an accent in English).
    public static var realtimeVoice: String {
        let v = (UserDefaults.standard.string(forKey: realtimeVoiceKey) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !v.isEmpty { return v }
        return conversationLanguage == .chinese ? "Tina" : "Jennifer"
    }
    /// The Qwen realtime model ID, user-editable (blank → the default).
    public static var qwenRealtimeModel: String {
        let v = (UserDefaults.standard.string(forKey: qwenRealtimeModelKey) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return v.isEmpty ? qwenRealtimeModelDefault : v
    }
}
