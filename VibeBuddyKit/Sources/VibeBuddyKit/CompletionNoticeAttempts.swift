import Foundation
import CryptoKit

/// Durable reservation before handing an initial completion to a channel.
/// A reservation is an attempt, never proof of delivery or of being heard.
public actor CompletionNoticeAttempts {
    public static let shared = CompletionNoticeAttempts()
    private let defaults: UserDefaults
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    public func claim(_ notice: CompletionNotice, recipient: String) -> Bool {
        let digest = SHA256.hash(data: Data((notice.id + "/" + recipient).utf8))
            .map { String(format: "%02x", $0) }.joined()
        let key = "completionNoticeAttempts"
        var entries = defaults.dictionary(forKey: key) as? [String: Double] ?? [:]
        guard entries[digest] == nil else { return false }
        let now = Date().timeIntervalSince1970
        entries = entries.filter { $0.value > now - 7 * 86400 }
        entries[digest] = now
        defaults.set(entries, forKey: key)
        return defaults.synchronize()
    }
}
