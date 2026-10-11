import CryptoKit
import Foundation
import VibeBuddyKit

/// A delivered notification/reply, never a command or approval.
public struct GrokBotResult: Codable, Equatable, Sendable {
    public enum Evidence: String, Codable, Sendable { case finalReply, notification }
    public let version: Int
    public let evidence: Evidence
    public let id: String
    public let botID: String
    public let conversationID: String
    public let turnID: String
    public let botName: String
    public let title: String
    public let text: String
    public let completedAt: Date

    public var sessionID: String {
        let data = (try? JSONEncoder().encode([botID, conversationID, turnID])) ?? Data()
        return "grokbot-result:" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func validate(now: Date) throws {
        guard version == 1,
              [id, botID, conversationID, turnID].allSatisfy({ !$0.isEmpty && $0.utf8.count <= 256 && !$0.contains(where: { $0.isNewline }) }),
              !botName.isEmpty, botName.count <= 120, !title.isEmpty, title.count <= 240,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.count <= 11_800,
              completedAt.timeIntervalSince1970.isFinite, completedAt <= now.addingTimeInterval(5),
              completedAt > now.addingTimeInterval(-7 * 86_400) else { throw Failure.invalid }
    }

    enum Failure: Error { case invalid, conflict, storage }
}

/// Owns a bounded, durable inbox. The ingest-only token cannot access phone routes.
public actor GrokBotResultInbox {
    public let token: String
    private let directory: URL
    private let journal: GrokBotInboxJournal

    public init(token: String, directory: URL) {
        self.token = token
        self.directory = directory
        self.journal = GrokBotInboxJournal(directory: directory)
    }

    /// Opt-in: installation provisions a separate owner-only token file.
    public static func configured(directory: URL? = nil) -> GrokBotResultInbox? {
        let root = directory ?? ProcessInfo.processInfo.environment["VIBEBUDDY_GROK_BOT_BRIDGE_DIRECTORY"].flatMap {
            $0.hasPrefix("/") ? URL(fileURLWithPath: $0) : nil
        } ?? TokenStore.defaultStore().fileURL.deletingLastPathComponent()
        let file = root.appendingPathComponent("grok-bot-result-token")
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
              let mode = attributes[.posixPermissions] as? NSNumber, mode.intValue & 0o077 == 0,
              let token = TokenStore(fileURL: file).load(), token.count >= 32 else { return nil }
        return GrokBotResultInbox(token: token, directory: root.appendingPathComponent("grok-bot-results"))
    }

    public func enabledAt(account: String, now: Date) throws -> Date {
        try journal.enable(account: account, now: now)
    }

    public func restore(account: String?, store: SessionStore, now: Date = Date()) async throws {
        await bind(store)
        try journal.migrateLegacy(account: account, unread: await store.grokBotLegacyUnreadStates(), now: now)
        for record in try journal.unread(account: account, now: now) {
            await store.ingestGrokBotResult(record.result, now: now, recovered: true)
        }
    }

    private func bind(_ store: SessionStore) async {
        let journal = self.journal
        await store.configureGrokBotInbox(read: { try journal.setRead($0, unread: $1) }, claim: { try journal.claim($0) })
    }

    public func receive(_ result: GrokBotResult, store: SessionStore, now: Date = Date(),
                        account: String? = nil, recovered: Bool = false) async throws -> Bool {
        try result.validate(now: now)
        let duplicate = try journal.accept(result, account: account, now: now)
        await bind(store)
        if !duplicate {
            if !recovered { _ = try journal.claim([result.sessionID]) }
            await store.ingestGrokBotResult(result, now: now, recovered: recovered)
        } else if try journal.isUnread(result.sessionID, account: account, now: now) {
            // A prior attempt may have committed the payload and then stopped
            // before projection. Reconstruct quietly, never reannounce a retry.
            await store.ingestGrokBotResult(result, now: now, recovered: true)
        }
        return duplicate
    }
}
