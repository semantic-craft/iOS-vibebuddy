import Foundation
import CryptoKit
import VibeBuddyKit

/// Auth is applied by VibeBuddyServer before this read-only adapter is entered.
/// A new repository per request avoids the mtime/size transcript cache.
public actor HistoryHTTPReader {
    public struct Result: Sendable { public let status: Int; public let data: Data }
    private struct Cursor { let sourceID: String; let key: String; let revision: String; let before: Int; let issued: Date }
    private var cursors: [String: Cursor] = [:]
    private var busy = false
    private let repository: @Sendable () -> SessionHistoryRepository
    private let now: @Sendable () -> Date
    private let ttl: TimeInterval
    private let maximumBytes = 1_048_576
    public init(repository: @escaping @Sendable () -> SessionHistoryRepository = {
        SessionHistoryRepository(cacheDirectory: FileManager.default.temporaryDirectory
            .appendingPathComponent("vibebuddy-history-" + UUID().uuidString), readOnly: true)
    }, now: @escaping @Sendable () -> Date = { Date() }, ttl: TimeInterval = 300) {
        self.repository = repository; self.now = now; self.ttl = ttl
    }

    private func failure(_ status: Int, _ reason: String) -> Result {
        Result(status: status, data: (try? JSONEncoder().encode(HistoryFailure(reason))) ?? Data())
    }

    public func read(uri: String, sourceID: String?) async -> Result {
        guard uri.utf8.count <= 2048, let parts = URLComponents(string: uri),
              parts.path == "/history", parts.fragment == nil,
              let items = parts.queryItems, items.allSatisfy({ $0.value != nil }),
              Set(items.map(\.name)).count == items.count,
              Set(items.map(\.name)).isSubset(of: ["sourceID", "key", "limit", "cursor"]) else {
            return failure(400, "invalid_request")
        }
        let values = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value!) })
        guard let requestedSource = values["sourceID"], !requestedSource.isEmpty,
              let key = values["key"], key.utf8.count <= 256,
              !key.hasPrefix("vibebuddy:"), let reference = try? HistorySessionReference(key), reference.key == key else {
            return failure(400, "invalid_request")
        }
        guard let limit = Int(values["limit"] ?? "30"), (1...100).contains(limit) else { return failure(400, "invalid_limit") }
        guard let sourceID, sourceID == requestedSource else { return failure(409, "source_changed") }
        guard reference.agent.supportsTranscript else { return failure(422, "unsupported_agent") }
        let time = now()
        cursors = cursors.filter { time.timeIntervalSince($0.value.issued) < ttl }
        let cursor: Cursor?
        if let token = values["cursor"] {
            guard let saved = cursors[token], saved.key == key, saved.sourceID == sourceID else { return failure(409, "cursor_expired") }
            cursor = saved
        } else { cursor = nil }
        guard !busy else { return failure(429, "reader_busy") }
        busy = true
        defer { busy = false }
        do {
            // Repository actor runs synchronous parsing on its own executor. Await permits
            // this actor to reject concurrent requests instead of accumulating parse work.
            let transcript = try await repository().readTranscript(key: key)
            let session = transcript.session
            guard session.isAvailable else { return failure(503, "source_unavailable") }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let visible = session.messages.filter { $0.kind != .meta && $0.kind != .thinking }
            let messages = try JSONDecoder().decode([HistoryMessage].self, from: encoder.encode(visible))
            struct Revision: Encodable {
                let sourceID: String; let key: String; let projection = "raw-visible-v1"
                let parserRevision = "history-parser-2"; let messages: [HistoryMessage]; let warnings: [String]
            }
            let digest = try encoder.encode(Revision(sourceID: sourceID, key: key, messages: messages, warnings: session.warnings))
            let revision = SHA256.hash(data: digest).map { String(format: "%02x", $0) }.joined()
            guard cursor == nil || cursor?.revision == revision else { return failure(409, "revision_changed") }
            let end = cursor?.before ?? messages.count
            guard end <= messages.count else { return failure(409, "revision_changed") }
            var start = max(0, end - limit)
            let limited = session.warnings.contains { $0.contains("32 MiB reading limit") }
            while true {
                let next = start > 0 ? UUID().uuidString : nil
                let page = HistoryPage(sourceID: sourceID, key: key, revision: revision,
                    messages: Array(messages[start..<end]), start: start, end: end, totalMessages: messages.count,
                    nextCursor: next, coverage: session.warnings.isEmpty ? "parsed-visible" : "partial",
                    sourceLimitReached: limited, warnings: session.warnings)
                let data = try encoder.encode(page)
                if data.count <= maximumBytes {
                    if let next {
                        if cursors.count >= 256, let oldest = cursors.min(by: { $0.value.issued < $1.value.issued })?.key { cursors.removeValue(forKey: oldest) }
                        cursors[next] = Cursor(sourceID: sourceID, key: key, revision: revision, before: start, issued: time)
                    }
                    return Result(status: 200, data: data)
                }
                guard start < end - 1 else { return failure(422, "message_exceeds_budget") }
                start += 1
            }
        } catch {
            // Do not expose repository errors, which can include local filesystem paths.
            let text = String(describing: error)
            if text.contains("Unknown session key") { return failure(404, "session_not_found") }
            if text.contains("Ambiguous session key") { return failure(409, "ambiguous_source") }
            if text.contains("identity does not match") { return failure(409, "identity_mismatch") }
            if text.contains("Source changed while reading") { return failure(409, "source_changed_during_read") }
            return failure(503, "source_unavailable")
        }
    }
}
