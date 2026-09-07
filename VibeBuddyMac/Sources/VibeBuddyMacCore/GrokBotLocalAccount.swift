import CommonCrypto
import CryptoKit
import Foundation
import Security

/// The active account in the official Grok Bot app. Never falls back to Cursor.
public struct GrokBotLocalAccount: Sendable {
    public let accessToken: String
    public let accountScope: String
    public let accountIdentity: String
    public let accountLabel: String
    public let teamID: String?

    public static let storeURL = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Application Support/Grok Bot/sand-secrets.json")

    /// Background collectors never ask macOS to present authorization UI.
    public static func load(allowPrompt: Bool = false) async throws -> Self {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(with: Result {
                    let data = try Data(contentsOf: storeURL)
                    let password = try readSafeStoragePassword(allowPrompt: allowPrompt)
                    return try decode(data, password: password, now: Date())
                })
            }
        }
    }

    static func readSafeStoragePassword(allowPrompt: Bool = false) throws -> String {
    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "Grok Bot Safe Storage",
        kSecReturnData as String: true,
        kSecMatchLimit as String: kSecMatchLimitOne,
        kSecUseAuthenticationUI as String: allowPrompt ? kSecUseAuthenticationUIAllow : kSecUseAuthenticationUIFail
    ]
    var item: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
          let bytes = item as? Data,
          let password = String(data: bytes, encoding: .utf8) else {
        throw AccountUsageError.notLoggedIn
    }
        return password
    }

    public static func activeIdentity() throws -> String {
        try cacheIdentity(Data(contentsOf: storeURL))
    }

    static func cacheIdentity(_ data: Data) throws -> String {
        let accounts = try record(data)
        let team = accounts.accounts[accounts.active]?["cursor-selected-team-id"] ?? "personal"
        return SHA256.hash(data: Data((accounts.active + ":" + team).utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private struct Accounts: Decodable {
        let active: String
        let accounts: [String: [String: String]]
    }

    private static func record(_ data: Data) throws -> Accounts {
        guard let store = try? JSONDecoder().decode([String: String].self, from: data),
              let raw = store["cursor-accounts"],
              let accounts = try? JSONDecoder().decode(Accounts.self, from: Data(raw.utf8)),
              accounts.accounts[accounts.active] != nil else { throw AccountUsageError.notLoggedIn }
        return accounts
    }

    static func decode(_ data: Data, password: String, now: Date) throws -> Self {
        let accounts = try record(data)
        guard let slots = accounts.accounts[accounts.active], let encrypted = slots["cursor-access-token"] else {
            throw AccountUsageError.notLoggedIn
        }
        let token = try decryptStoredSecret(encrypted, password: password)
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { throw AccountUsageError.notLoggedIn }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let bytes = Data(base64Encoded: payload),
              let claims = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              let sub = claims["sub"] as? String,
              let exp = claims["exp"] as? Double, exp.isFinite, exp > now.timeIntervalSince1970 + 60 else {
            throw AccountUsageError.notLoggedIn
        }
        let scope = SHA256.hash(data: Data(sub.utf8)).map { String(format: "%02x", $0) }.joined()
        guard scope == accounts.active else { throw AccountUsageError.notLoggedIn }
        let email = claims["email"] as? String
        let label: String
        if let email, let at = email.firstIndex(of: "@"), at != email.startIndex {
            label = "\(email.prefix(1))***\(email[at...])"
        } else { label = "Account \(scope.prefix(8))" }
        let team = try slots["cursor-selected-team-id"].map { try decryptStoredSecret($0, password: password) }
        if let team, Int(team).map({ $0 > 0 }) != true { throw AccountUsageError.incompatibleFormat }
        return Self(accessToken: token, accountScope: scope, accountIdentity: try cacheIdentity(data), accountLabel: label, teamID: team)
    }

    /// Electron macOS safeStorage v10. Password exists only for this operation.
    static func decryptStoredSecret(_ raw: String, password: String) throws -> String {
        let value: String
        if raw.hasPrefix("scoped:v1:") {
            let parts = raw.split(separator: ":", maxSplits: 3, omittingEmptySubsequences: false)
            guard parts.count == 4 else { throw AccountUsageError.incompatibleFormat }
            value = String(parts[3])
        } else { value = raw }
        guard let encrypted = Data(base64Encoded: value), encrypted.starts(with: Data("v10".utf8)) else {
            throw AccountUsageError.incompatibleFormat
        }
        let passwordBytes = Array(password.utf8), salt = Array("saltysalt".utf8)
        var key = [UInt8](repeating: 0, count: kCCKeySizeAES128)
        let derivation = passwordBytes.withUnsafeBytes { p in
            salt.withUnsafeBytes { s in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), p.baseAddress?.assumingMemoryBound(to: Int8.self), p.count,
                    s.baseAddress?.assumingMemoryBound(to: UInt8.self), s.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 1003, &key, key.count)
            }
        }
        guard derivation == kCCSuccess else { throw AccountUsageError.unknown }
        let input = Data(encrypted.dropFirst(3)), iv = [UInt8](repeating: 32, count: kCCBlockSizeAES128)
        var output = [UInt8](repeating: 0, count: input.count + kCCBlockSizeAES128), count = 0
        let capacity = output.count
        let status = input.withUnsafeBytes { bytes in
            CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                key, key.count, iv, bytes.baseAddress, bytes.count, &output, capacity, &count)
        }
        guard status == kCCSuccess, let text = String(bytes: output.prefix(count), encoding: .utf8) else {
            throw AccountUsageError.notLoggedIn
        }
        return text
    }
}
