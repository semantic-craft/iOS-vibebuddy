import Foundation

/// Who continued whom (ADR-0023 amendment, ticket handoff-continue-hardening/02).
/// One record per Continue with… the Mac dispatched: the receiver's Session
/// key, the source's, the handoff it started from (if any) and when. A
/// session's `continuesSessionKey` and a handoff record's `takenBy` are
/// derived from these records, never kept separately; `facts` prints the
/// receiver's `Continues:` line from the same file. Keys and paths only —
/// no prompt, no title, no token.
///
/// Owner-only JSON, atomic writes, seven days from `recordedAt`.
public struct ContinuationRecord: Codable, Equatable, Sendable {
    public var receiverKey: String
    public var sourceKey: String
    public var handoffPath: String?
    public var recordedAt: Date
    public init(receiverKey: String, sourceKey: String, handoffPath: String?, recordedAt: Date) {
        self.receiverKey = receiverKey; self.sourceKey = sourceKey; self.handoffPath = handoffPath; self.recordedAt = recordedAt
    }
}

struct ContinuationLedger {
    static let retention: TimeInterval = 7 * 86_400
    static let fileName = "continuations.json"

    let url: URL?
    private(set) var records: [ContinuationRecord] = []
    private var available = true

    init(url: URL?, now: Date = Date()) {
        self.url = url
        guard let url else { return }
        let read = Self.read(url: url, now: now)
        records = read.records
        available = read.readable
    }

    /// Decode without pruning or persisting — for `facts` in another process.
    static func read(url: URL, now: Date) -> (records: [ContinuationRecord], readable: Bool) {
        do {
            let all = try JSONDecoder().decode([ContinuationRecord].self, from: Data(contentsOf: url))
            return (all.filter { $0.recordedAt >= now.addingTimeInterval(-retention) }, true)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return ([], true)
        } catch {
            return ([], false)
        }
    }

    mutating func record(receiverKey: String, sourceKey: String, handoffPath: String?, now: Date) {
        records.removeAll { $0.receiverKey == receiverKey }
        records.append(ContinuationRecord(receiverKey: receiverKey, sourceKey: sourceKey, handoffPath: handoffPath, recordedAt: now))
        records = records.filter { $0.recordedAt >= now.addingTimeInterval(-Self.retention) }
        save()
    }

    func sourceKey(forReceiver key: String) -> String? {
        records.last { $0.receiverKey == key }?.sourceKey
    }

    /// Receivers started from this handoff, oldest first.
    func takenBy(handoffPath: String) -> [String] {
        records.filter { $0.handoffPath == handoffPath }.sorted { $0.recordedAt < $1.recordedAt }.map(\.receiverKey)
    }

    private func save() {
        guard let url, available else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let data = try JSONEncoder().encode(records)
            try data.write(to: url, options: [.atomic, .completeFileProtection])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {}
    }
}
