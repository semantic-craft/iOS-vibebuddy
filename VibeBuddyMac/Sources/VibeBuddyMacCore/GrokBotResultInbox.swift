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

    public init(token: String, directory: URL) {
        self.token = token
        self.directory = directory
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

    public func receive(_ result: GrokBotResult, store: SessionStore, now: Date = Date()) async throws -> Bool {
        try result.validate(now: now)
        let key = result.sessionID
        let file = directory.appendingPathComponent(key + ".json")
        let decoder = JSONDecoder()
        let duplicate: Bool
        if FileManager.default.fileExists(atPath: file.path) {
            guard let data = try? Data(contentsOf: file), let previous = try? decoder.decode(GrokBotResult.self, from: data)
            else { throw GrokBotResult.Failure.storage }
            guard previous == result else { throw GrokBotResult.Failure.conflict }
            duplicate = true
        } else {
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                       attributes: [.posixPermissions: 0o700])
                let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])
                for old in files where old.pathExtension == "json" {
                    if let date = try? old.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                       date < now.addingTimeInterval(-7 * 86_400) { try? FileManager.default.removeItem(at: old) }
                }
                guard try FileManager.default.contentsOfDirectory(atPath: directory.path).count < 4096 else {
                    throw GrokBotResult.Failure.storage
                }
                try JSONEncoder().encode(result).write(to: file, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            } catch { throw GrokBotResult.Failure.storage }
            duplicate = false
        }
        // The durable file reserves identity before awaiting the store, including
        // after restart or user dismissal. Retrying must never reannounce a result.
        if !duplicate {
            await store.ingestGrokBotResult(result, now: now)
        }
        return duplicate
    }
}

