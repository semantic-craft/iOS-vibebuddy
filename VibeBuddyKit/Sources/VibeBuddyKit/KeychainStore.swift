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

/// The phone's stable push identity: one UUID, minted on first use and kept in
/// the Keychain, which outlives a reinstall and a device restore. Those are the
/// events that hand the app a new APNs token, and without an identity that
/// survives them the Mac's registry sees each new token as a new phone and keeps
/// the old one — with the switches it uploaded last time. See
/// `DeviceRegistrationPayload.deviceID`.
public enum PushDeviceIdentity {
    public static let keychainKey = "pushDeviceID"

    /// Reads the identity, minting and storing one when none exists. The
    /// storage is injectable so the rule can be tested without a Keychain.
    public static func current(
        read: (String) -> String? = KeychainStore.get,
        write: (String?, String) -> Void = KeychainStore.set,
        mint: () -> String = { UUID().uuidString }
    ) -> String {
        if let existing = read(keychainKey), !existing.isEmpty { return existing }
        let fresh = mint()
        write(fresh, keychainKey)
        return fresh
    }
}

/// The language the voice companion converses in — drives speech recognition,
/// the model's reply language, and the spoken voice. Independent of the app's UI
/// language (which is English).
public enum VoiceLanguage: String, CaseIterable, Sendable {
    case english = "en"
    case chinese = "zh"

    /// BCP-47 locale string for the realtime voice session's language.
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
    public static let regionIntlKey = "voiceRegionIntl"
    public static let qwenWorkspaceIDKey = "voiceQwenWorkspaceID"
    public static let conversationLanguageKey = "voiceConversationLanguage"
    public static let providerKey = "voiceProvider"
    public static let companionEnabledKey = "voiceCompanionEnabled"

    /// Per-provider model / voice ID UserDefaults keys (one set each).
    public static func modelKey(_ p: VoiceProvider) -> String { "voiceModel.\(p.rawValue)" }
    public static func voiceKey(_ p: VoiceProvider) -> String { "voiceVoice.\(p.rawValue)" }

    /// Beijing region by default; toggle for the Singapore (international) region.
    public static var useIntl: Bool { UserDefaults.standard.bool(forKey: regionIntlKey) }
    /// Bailian workspace ID (optional). When set, Qwen connects through the
    /// workspace-specific `{id}.<region>.maas.aliyuncs.com` endpoint that Alibaba
    /// now recommends; blank keeps the shared `dashscope` domain.
    public static var qwenWorkspaceID: String? {
        let v = (UserDefaults.standard.string(forKey: qwenWorkspaceIDKey) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return v.isEmpty ? nil : v
    }
    /// Conversation language; English by default to match the app UI.
    public static var conversationLanguage: VoiceLanguage {
        VoiceLanguage(rawValue: UserDefaults.standard.string(forKey: conversationLanguageKey) ?? "")
            ?? .english
    }

    /// Opt-in consent gate for the voice companion. Default **OFF**: tapping the
    /// buddy must not open the mic or share session context with a provider until
    /// the user deliberately enables it (absent key → `false` = hard default-off
    /// for everyone, including existing-key users after an update).
    public static var companionEnabled: Bool { UserDefaults.standard.bool(forKey: companionEnabledKey) }

    /// The active real-time voice provider.
    public static var provider: VoiceProvider {
        VoiceProvider(rawValue: UserDefaults.standard.string(forKey: providerKey) ?? "") ?? .qwen
    }

    /// The model ID for a provider, user-editable (blank → its default).
    public static func model(_ p: VoiceProvider) -> String {
        let v = (UserDefaults.standard.string(forKey: modelKey(p)) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return v.isEmpty ? p.defaultModel : v
    }

    /// The voice ID for a provider, user-editable (blank → a language-appropriate
    /// default). CN voices carry an accent in English, so the default is chosen
    /// from the conversation language.
    public static func voice(_ p: VoiceProvider, _ language: VoiceLanguage) -> String {
        let v = (UserDefaults.standard.string(forKey: voiceKey(p)) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return v.isEmpty ? p.defaultVoice(language) : v
    }
}
