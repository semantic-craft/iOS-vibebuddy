import Foundation
import VibeBuddyKit

/// The Mac's durable copy of verified completion results, by exact round.
///
/// A session carries one completion at a time, so without this file an
/// earlier round's original result (read on the phone, spoken, or used to
/// reject a conflicting read) is gone after a restart. Records are kept for
/// seven days, bounded by count and encoded size.
///
/// Persisted like `CompletionNoticeLedger`: owner-only JSON, atomic writes,
/// unavailable storage degrades to memory for this process only.
struct CompletionResultLedger {
    struct File: Codable, Equatable, Sendable {
        var results: [String: CompletionResults.Record]?
    }

    static let fileName = "completion-results.json"
    /// Results used to live inside the removed Recap's ledger; read them once.
    static let legacyFileName = "recap-ledger.json"

    static let maximumResults = 512
    static let maximumResultBytes = 8 * 1_024 * 1_024
    static let maximumFileBytes = 32 * 1_024 * 1_024

    static let retention: TimeInterval = 7 * 86_400

    let url: URL?
    private(set) var results: [String: CompletionResults.Record] = [:]
    private var available = true

    init(url: URL?, now: Date = Date()) {
        self.url = url
        guard let url else { return }
        let legacy = url.deletingLastPathComponent().appendingPathComponent(Self.legacyFileName)
        let migrating = !FileManager.default.fileExists(atPath: url.path)
            && FileManager.default.fileExists(atPath: legacy.path)
        do {
            let source = migrating ? legacy : url
            let size = try source.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= Self.maximumFileBytes else {
                if migrating { try? FileManager.default.removeItem(at: legacy) } else { available = false }
                return
            }
            let file = try JSONDecoder().decode(File.self, from: Data(contentsOf: source))
            results = Self.bounded(file.results ?? [:], now: now)
            // A migration whose delete failed earlier: the new file already holds the results.
            if !migrating { try? FileManager.default.removeItem(at: legacy) }
        } catch {
            // An unreadable legacy file cannot be recovered later; drop it
            // rather than keep the new store closed over the removed feature.
            if migrating { try? FileManager.default.removeItem(at: legacy); return }
            let failure = error as NSError
            // URL resource APIs can throw NSError without a CocoaError cast.
            // A missing new ledger is writable; other load failures stay closed.
            available = failure.domain == NSCocoaErrorDomain
                && failure.code == CocoaError.fileReadNoSuchFile.rawValue
        }
        if migrating, save(now: now) { try? FileManager.default.removeItem(at: legacy) }
    }

    static func bounded(_ records: [String: CompletionResults.Record], now: Date) -> [String: CompletionResults.Record] {
        var bytes = 0
        var kept: [String: CompletionResults.Record] = [:]
        for record in records.values.sorted(by: {
            $0.completedAt == $1.completedAt ? $0.id < $1.id : $0.completedAt > $1.completedAt
        }) where record.completedAt > now.addingTimeInterval(-retention) {
            guard kept.count < maximumResults else { break }
            guard records[record.id] == record, !record.sourceID.isEmpty, !record.sessionID.isEmpty,
                  !record.completionID.isEmpty, record.completedAt >= (record.startedAt ?? .distantPast),
                  record.agent != .codex || record.turnID?.isEmpty == false,
                  record.text.map({ $0.count <= 12_000 }) ?? true,
                  let data = try? JSONEncoder().encode(record), bytes + data.count <= maximumResultBytes else { continue }
            bytes += data.count
            kept[record.id] = record
        }
        return kept
    }

    mutating func retainResults(_ records: [String: CompletionResults.Record], now: Date) {
        let next = Self.bounded(records, now: now)
        guard next != results else { return }
        results = next
        save(now: now)
    }

    @discardableResult
    private mutating func save(now: Date) -> Bool {
        results = Self.bounded(results, now: now)
        guard let url else { return true }
        guard available else { return false }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let data = try JSONEncoder().encode(File(results: results))
            // macOS supports owner-only files here; completeFileProtection can
            // reject mktemp with EPERM. Keep atomic replacement inside the 0700 directory.
            try data.write(to: url, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            return false
        }
        return true
    }
}
