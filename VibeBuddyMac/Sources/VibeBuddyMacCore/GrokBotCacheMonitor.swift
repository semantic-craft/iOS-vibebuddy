import CryptoKit
import Foundation

/// Reads only the signed-in owner's desktop message replicas. A delivered text
/// message is a notification, not evidence that its task succeeded.
public actor GrokBotCacheMonitor {
    private let directory: URL
    private let scope: @Sendable () throws -> String
    private var baseline: Date?
    private let startedAt = Date()
    private var persistedBaseline: Date?
    private var seen: Set<String> = []
    private var activeScope: String?
    private var cache: [URL: (Date, Int, [String: Any])] = [:]
    public struct Status: Codable, Sendable {
        public var available = false
        public var replicaCount = 0
        public var lastPollAt: Date?
        public var lastDeliveryAt: Date?
        public var deliveryFailed = false
        public var historyMayBeIncomplete = false
        public let retentionDays = 7
    }
    private var health = Status()
    public func status() -> Status { health }

    public init(directory: URL, scope: @escaping @Sendable () throws -> String) {
        self.directory = directory
        self.scope = scope
    }

    public static func local() -> GrokBotCacheMonitor {
        let root = ProcessInfo.processInfo.environment["VIBEBUDDY_GROK_BOT_HOME"].flatMap {
            $0.hasPrefix("/") ? URL(fileURLWithPath: $0) : nil
        } ?? GrokBotLocalAccount.storeURL.deletingLastPathComponent()
        return .init(directory: root.appendingPathComponent("sand-client-persistence"),
              scope: { try GrokBotLocalAccount.activeAccountScope(store: root.appendingPathComponent("sand-secrets.json")) })
    }

    public func run(inbox: GrokBotResultInbox, store: SessionStore) async {
        while !Task.isCancelled {
            do {
                let currentScope = try scope()
                await store.setGrokBotRecoveryCollecting(true)
                if activeScope != currentScope {
                    await store.retireGrokBotResults(now: Date())
                    persistedBaseline = try await inbox.enabledAt(account: currentScope, now: Date())
                    guard try scope() == currentScope else { continue }
                    try await inbox.restore(account: currentScope, store: store)
                    try await inbox.restore(account: nil, store: store)
                }
                let results = try poll(now: Date(), since: persistedBaseline)
                for (index, result) in results.enumerated() {
                    guard !Task.isCancelled else { return }
                    do {
                        if try scope() != currentScope { break }
                    } catch {
                        for pending in results.dropFirst(index) { seen.remove(pending.sessionID) }
                        throw error
                    }
                    do {
                        _ = try await inbox.receive(result, store: store, account: currentScope, recovered: result.completedAt < startedAt)
                        health.lastDeliveryAt = Date(); health.deliveryFailed = false
                    } catch GrokBotResult.Failure.invalid { health.deliveryFailed = true
                    } catch GrokBotResult.Failure.conflict { health.deliveryFailed = true
                    } catch { seen.remove(result.sessionID); health.deliveryFailed = true }
                }
            } catch {
                health.available = false
                // Cache rotation/read failure is not logout. Only loss/change
                // of the active account is allowed to retire visible results.
                if (try? scope()) != activeScope {
                    activeScope = nil
                    await store.retireGrokBotResults(now: Date())
                }
            }
            await store.setGrokBotRecoveryCollecting(false)
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
        }
    }

    public func poll(now: Date, since: Date? = nil) throws -> [GrokBotResult] {
        let account = try scope()
        if activeScope != account {
            activeScope = account; baseline = since ?? now; seen.removeAll(); cache.removeAll()
        }
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey])
        var names: [String: String] = [:]
        var directBots: Set<String> = []
        var replicas: [(String, [String: Any])] = []
        for file in files where file.pathExtension == "blob" {
            guard let key = Self.decodeKey(file.deletingPathExtension().lastPathComponent),
                  key.hasPrefix("sand.client.slice.account."),
                  let marker = key.range(of: ".roster.last-roster") ?? key.range(of: ".transcript.replicas.") else { continue }
            let encoded = String(key[key.index(key.startIndex, offsetBy: "sand.client.slice.account.".count)..<marker.lowerBound])
            guard let subject = encoded.removingPercentEncoding,
                  Self.hash(subject) == account else { continue }
            guard let info = try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey]) else { continue }
            guard info.isRegularFile == true, info.isSymbolicLink != true, let size = info.fileSize,
                  size <= 8 * 1_024 * 1_024, let modified = info.contentModificationDate else { continue }
            let value: [String: Any]
            if let previous = cache[file], previous.0 == modified, previous.1 == size { value = previous.2 }
            else {
                guard let data = try? Data(contentsOf: file),
                      let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let decoded = root["value"] as? [String: Any] else { continue }
                value = decoded; cache[file] = (modified, size, decoded)
            }
            if key.hasSuffix(".roster.last-roster") {
                for row in value["rows"] as? [[String: Any]] ?? [] {
                    if let id = row["id"] as? String, let name = row["name"] as? String {
                        names[id] = name
                        if row["isGroup"] as? Bool == false { directBots.insert(id) }
                    }
                }
            } else { replicas.append((String(key[marker.upperBound...]), value)) }
        }
        cache = cache.filter { files.contains($0.key) }
        var results: [GrokBotResult] = []
        health.historyMayBeIncomplete = false
        for (conversation, value) in replicas {
            if let preceding = value["precedingTimestampMs"] as? NSNumber,
               Date(timeIntervalSince1970: preceding.doubleValue / 1000) > max(baseline ?? now, now.addingTimeInterval(-7 * 86_400)) {
                health.historyMayBeIncomplete = true
            }
            for entry in value["entries"] as? [[String: Any]] ?? [] {
                guard entry["kind"] as? String == "send-message",
                      entry["deliverTo"] == nil,
                      let message = entry["message"] as? [String: Any], message["type"] as? String == "text",
                      let text = message["content"] as? String,
                      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.count <= 11_800,
                      let id = entry["id"] as? String,
                      let stamp = entry["timestampMs"] as? NSNumber else { continue }
                let author = entry["author"] as? [String: Any]
                guard let bot = author?["id"] as? String ?? (directBots.contains(conversation) ? conversation : nil),
                      directBots.contains(bot) else { continue }
                let date = Date(timeIntervalSince1970: stamp.doubleValue / 1000)
                let botName = [author?["name"] as? String, names[bot]]
                    .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .first { !$0.isEmpty } ?? "Grok Bot"
                let result = GrokBotResult(version: 1, evidence: .notification,
                    id: id, botID: account + ":" + bot, conversationID: conversation, turnID: id,
                    botName: String(botName.prefix(120)),
                    title: "Grok Bot 通知", text: text, completedAt: date)
                guard date >= max(baseline ?? now, now.addingTimeInterval(-7 * 86_400)), date <= now, !seen.contains(result.sessionID) else { continue }
                seen.insert(result.sessionID)
                results.append(result)
            }
        }
        do {
            guard try scope() == account else { return [] }
        } catch {
            for result in results { seen.remove(result.sessionID) }
            throw error
        }
        health.available = true; health.replicaCount = replicas.count; health.lastPollAt = now
        if seen.count > 20_000 { seen.removeAll() }
        return results.sorted { $0.completedAt < $1.completedAt }
    }

    private static func hash(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func decodeKey(_ text: String) -> String? {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567".utf8)
        var accumulator = 0, bits = 0, output: [UInt8] = []
        for byte in text.uppercased().utf8 where byte != 61 {
            guard let digit = alphabet.firstIndex(of: byte) else { return nil }
            accumulator = (accumulator << 5) | digit; bits += 5
            if bits >= 8 { bits -= 8; output.append(UInt8((accumulator >> bits) & 255)); accumulator &= (1 << bits) - 1 }
        }
        return String(bytes: output, encoding: .utf8)
    }
}
