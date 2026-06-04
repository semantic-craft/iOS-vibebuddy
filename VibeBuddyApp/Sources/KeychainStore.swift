import Foundation
import Security

/// Minimal Keychain wrapper for the one secret we hold: the DashScope API key.
/// Never written to UserDefaults or committed.
enum KeychainStore {
    private static let service = "com.vibebuddy.app.secrets"

    static func set(_ value: String?, for key: String) {
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

    static func get(_ key: String) -> String? {
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

/// Names for the secrets/settings the voice companion uses.
enum VoiceSettings {
    static let apiKeyKeychain = "dashscope.apiKey"
    static let enabledKey = "voiceCompanionEnabled"
    static let modelKey = "voiceModel"
    static let regionIntlKey = "voiceRegionIntl"

    static var apiKey: String? { KeychainStore.get(apiKeyKeychain) }
    static var enabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }
    static var model: String { UserDefaults.standard.string(forKey: modelKey) ?? "qwen-plus" }
    /// China (Beijing) endpoint by default; toggle for the international site.
    static var useIntl: Bool { UserDefaults.standard.bool(forKey: regionIntlKey) }
}
