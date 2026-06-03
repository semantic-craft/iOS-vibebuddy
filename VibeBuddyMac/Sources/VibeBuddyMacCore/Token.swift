import Foundation

/// A LAN bearer token. Random, not a credential store — just enough to stop a
/// stranger on the same WiFi from reading your sessions.
public enum Token {
    public static func generate() -> String {
        (0..<16).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
    }
}

/// Generates the token once and persists it to a file so a given Mac keeps a
/// stable token across launches (the phone pairs with it via QR).
public struct TokenStore: Sendable {
    public let fileURL: URL

    public init(fileURL: URL) { self.fileURL = fileURL }

    /// ~/Library/Application Support/vibebuddy/token
    public static func defaultStore() -> TokenStore {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return TokenStore(fileURL: base.appendingPathComponent("vibebuddy/token"))
    }

    public func loadOrCreate() throws -> String {
        if let data = try? Data(contentsOf: fileURL),
           let existing = String(data: data, encoding: .utf8)?
               .trimmingCharacters(in: .whitespacesAndNewlines),
           !existing.isEmpty {
            return existing
        }
        let token = Token.generate()
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(token.utf8).write(to: fileURL, options: .atomic)
        return token
    }
}
