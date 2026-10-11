import Foundation

/// One atomic file commits payload, read state and speech claims together.
/// Shared with SessionStore's synchronous acknowledgement path; all access is locked.
final class GrokBotInboxJournal: @unchecked Sendable {
    struct Record: Codable, Equatable {
        var result: GrokBotResult
        var account: String?
        var read = false
        var announced = false
    }
    struct State: Codable, Equatable {
        var version = 1
        var enabledAt: [String: Date] = [:]
        var records: [String: Record] = [:]
    }
    private let lock = NSLock()
    private let directory: URL
    private var state: State?
    init(directory: URL) {
        self.directory = directory
        let file = directory.appendingPathComponent("inbox-state.json")
        if FileManager.default.fileExists(atPath: file.path) {
            if let data = try? Data(contentsOf: file), let value = try? JSONDecoder().decode(State.self, from: data), value.version == 1 {
                state = value
            }
        } else { state = State() }
    }
    private func transaction<T>(_ body: (inout State) throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        guard var next = state else { throw GrokBotResult.Failure.storage }
        let result = try body(&next)
        if next == state { return result }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = directory.appendingPathComponent("inbox-state.json")
        try JSONEncoder().encode(next).write(to: file, options: [.atomic, .completeFileProtectionUnlessOpen])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        state = next
        return result
    }
    func enable(account: String, now: Date) throws -> Date {
        try transaction { state in
            if let date = state.enabledAt[account] { return date }
            state.enabledAt[account] = now
            return now
        }
    }
    func accept(_ result: GrokBotResult, account: String?, now: Date) throws -> Bool {
        try transaction { state in
            if let old = state.records[result.sessionID] {
                guard old.result == result, old.account == account else { throw GrokBotResult.Failure.conflict }
                return true
            }
            // Legacy files are deduplication tombstones: their old format cannot
            // distinguish read from unread. Do not resurrect dismissed v1 cards.
            let legacy = directory.appendingPathComponent(result.sessionID + ".json")
            if FileManager.default.fileExists(atPath: legacy.path) {
                guard let old = try? JSONDecoder().decode(GrokBotResult.self, from: Data(contentsOf: legacy)), old == result else {
                    throw GrokBotResult.Failure.conflict
                }
                return true
            }
            state.records = state.records.filter { $0.value.result.completedAt > now.addingTimeInterval(-7 * 86_400) }
            guard state.records.count < 4096 else { throw GrokBotResult.Failure.storage }
            state.records[result.sessionID] = Record(result: result, account: account)
            return false
        }
    }
    func migrateLegacy(account: String?, unread: [String: Bool], now: Date) throws {
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        var legacy: [GrokBotResult] = []
        for file in files where file.lastPathComponent.hasPrefix("grokbot-result:") && file.pathExtension == "json" {
            let info = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard info.isRegularFile == true, info.isSymbolicLink != true,
                  let result = try? JSONDecoder().decode(GrokBotResult.self, from: Data(contentsOf: file)),
                  (try? result.validate(now: now)) != nil else { continue }
            let prefix = String(result.botID.split(separator: ":").first ?? "")
            let scoped = prefix.count == 64 && prefix.allSatisfy { $0.isHexDigit } ? prefix : nil
            if scoped == account { legacy.append(result) }
        }
        guard !legacy.isEmpty else { return }
        try transaction { state in
            for result in legacy where state.records[result.sessionID] == nil {
                guard state.records.count < 4096 else { throw GrokBotResult.Failure.storage }
                state.records[result.sessionID] = Record(result: result, account: account,
                    read: unread[result.sessionID] != true, announced: true)
            }
        }
    }

    func unread(account: String?, now: Date) throws -> [Record] {
        lock.lock(); defer { lock.unlock() }
        guard let state else { throw GrokBotResult.Failure.storage }
        return state.records.values.filter { $0.account == account && !$0.read && $0.result.completedAt > now.addingTimeInterval(-7 * 86_400) }
            .sorted { $0.result.completedAt < $1.result.completedAt }
    }
    func isUnread(_ id: String, account: String?, now: Date) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let state else { throw GrokBotResult.Failure.storage }
        guard let record = state.records[id] else { return false }
        return record.account == account && !record.read && record.result.completedAt > now.addingTimeInterval(-7 * 86_400)
    }
    func setRead(_ id: String, unread: Bool) throws {
        try transaction { state in
            // An expired record may still have a visible card in a long-lived app.
            // Its retention tombstone is implicit; acknowledging it cannot resurrect it.
            guard state.records[id] != nil else { return }
            state.records[id]?.read = !unread
            // Mark unread is a card action, never permission to reannounce.
            state.records[id]?.announced = true
        }
    }
    func claim(_ ids: Set<String>) throws -> Int {
        try transaction { state in
            var count = 0
            for id in ids where state.records[id]?.read == false && state.records[id]?.announced == false {
                state.records[id]?.announced = true
                count += 1
            }
            return count
        }
    }
}
