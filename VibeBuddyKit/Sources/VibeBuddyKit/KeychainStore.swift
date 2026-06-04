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

/// Names + accessors for the voice companion's settings. The API key lives in the
/// Keychain (user-provided, BYO); the rest are plain UserDefaults toggles.
public enum VoiceSettings {
    public static let apiKeyKeychain = "dashscope.apiKey"
    public static let enabledKey = "voiceCompanionEnabled"
    public static let modelKey = "voiceModel"
    public static let regionIntlKey = "voiceRegionIntl"

    public static var apiKey: String? { KeychainStore.get(apiKeyKeychain) }
    public static var enabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }
    public static var model: String { UserDefaults.standard.string(forKey: modelKey) ?? "qwen-plus" }
    /// China (Beijing) endpoint by default; toggle for the international site.
    public static var useIntl: Bool { UserDefaults.standard.bool(forKey: regionIntlKey) }
}
