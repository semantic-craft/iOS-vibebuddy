import Foundation
import Security
import VibeBuddyMacCore

/// Stores the LAN bearer token in the login Keychain (generic password) instead
/// of a plaintext file. Stable across launches so the phone stays paired.
enum KeychainTokenStore {
    private static let service = "com.vibebuddy.mac"
    private static let account = "lan-token"

    static func loadOrCreate() -> String {
        if let existing = load() { return existing }
        let token = Token.generate()
        save(token)
        return token
    }

    private static func load() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let token = String(data: data, encoding: .utf8)
        else { return nil }
        return token
    }

    private static func save(_ token: String) {
        let identity: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(identity as CFDictionary)
        var add = identity
        add[kSecValueData as String] = Data(token.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }
}
