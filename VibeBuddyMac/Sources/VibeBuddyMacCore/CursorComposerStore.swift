import Foundation
import SQLite3
import VibeBuddyKit

/// One Cursor conversation as Cursor itself records it.
public struct CursorComposer: Equatable, Sendable {
    public let id: String
    /// Cursor's own chat title.
    public let name: String?
    /// Cursor's one-line "what just happened" ("Edited settings.json").
    public let subtitle: String?
    public let project: String?
    public let branch: String?
    public let model: String?
    public let contextTokens: Int?
    public let contextWindow: Int?
    /// Cursor's own `status` on the conversation: `completed`, `aborted`,
    /// `none` for one that never ran. Absent on older layouts.
    public let status: String?
    /// Cursor says the chat is blocked on something the person must act on.
    public let blockingPendingActions: Bool
    public let isSubagent: Bool
    public let isArchived: Bool
    public let isDraft: Bool
    /// A cloud ("background") agent rather than one running on this Mac.
    public let isCloud: Bool
    public let updatedAt: Date

    public init(id: String, name: String? = nil, subtitle: String? = nil, project: String? = nil,
                branch: String? = nil, model: String? = nil, contextTokens: Int? = nil,
                contextWindow: Int? = nil, status: String? = nil,
                blockingPendingActions: Bool = false, isSubagent: Bool = false,
                isArchived: Bool = false, isDraft: Bool = false, isCloud: Bool = false,
                updatedAt: Date) {
        self.id = id
        self.name = name
        self.subtitle = subtitle
        self.project = project
        self.branch = branch
        self.model = model
        self.contextTokens = contextTokens
        self.contextWindow = contextWindow
        self.status = status
        self.blockingPendingActions = blockingPendingActions
        self.isSubagent = isSubagent
        self.isArchived = isArchived
        self.isDraft = isDraft
        self.isCloud = isCloud
        self.updatedAt = updatedAt
    }

    /// A conversation Cursor has actually run, as opposed to an empty draft the
    /// person opened and left. Only these are worth a row.
    public var hasRun: Bool {
        guard !isDraft, status != "none" else { return false }
        return name != nil || subtitle != nil || contextTokens != nil
    }
}

/// Reads Cursor's conversation index out of its own state database.
///
/// `~/Library/Application Support/Cursor/User/globalStorage/state.vscdb` is a
/// SQLite key/value store. On Cursor 3.x the index lives in a dedicated
/// `composerHeaders` table (`composerId`, `workspaceId`, `recency`, `isSubagent`
/// and a JSON `value` head) with per-conversation detail under
/// `cursorDiskKV`'s `composerData:<id>`; older builds keep only the
/// `composerData:` keys, so both are read and merged.
///
/// This is the only place the *current* state of a conversation can be learned
/// without hooks: `composerData.status`, `contextTokensUsed` /
/// `contextTokenLimit`, `modelConfig.modelName`, the tracked repo and branch, and
/// `hasBlockingPendingActions`.
///
/// Like `CopilotSessionReader`, it works from a private snapshot so SQLite's own
/// WAL bookkeeping can never write into Cursor's directory, and a database that
/// changed mid-copy is retried on the next pass rather than half-read.
public struct CursorComposerStore: Sendable {
    public let database: URL
    private var stamp: [String]?

    public init(database: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")) {
        self.database = database
    }

    public enum ReadError: Error { case unreadable, changedDuringRead }

    /// nil means unchanged since the last read; an empty array means a database
    /// that was read successfully and holds no conversations.
    public mutating func refresh() throws -> [CursorComposer]? {
        let before = signature()
        guard before != stamp else { return nil }
        stamp = nil  // a failed read must be retried, even back to a prior signature
        guard FileManager.default.fileExists(atPath: database.path) else {
            stamp = before
            return []
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vibebuddy-cursor-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let copy = directory.appendingPathComponent("state.vscdb")
        for suffix in ["", "-wal"] {
            let source = URL(fileURLWithPath: database.path + suffix)
            if FileManager.default.fileExists(atPath: source.path) {
                try FileManager.default.copyItem(at: source, to: URL(fileURLWithPath: copy.path + suffix))
            }
        }
        guard signature() == before else { throw ReadError.changedDuringRead }
        var db: OpaquePointer?
        guard sqlite3_open_v2(copy.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db)
            throw ReadError.unreadable
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 250)
        let heads = try Self.heads(db: db)
        let details = try Self.details(db: db)
        var merged: [CursorComposer] = []
        for id in Set(heads.keys).union(details.keys).sorted() {
            guard let composer = Self.compose(id: id, head: heads[id], detail: details[id]) else { continue }
            merged.append(composer)
        }
        stamp = before
        return merged.sorted { $0.updatedAt > $1.updatedAt }
    }

    // MARK: - Reading

    struct Head {
        var workspaceID: String?
        var recency: Double?
        var isSubagent: Bool
        var isArchived: Bool
        var json: [String: Any]
    }

    static func heads(db: OpaquePointer?) throws -> [String: Head] {
        guard tableExists("composerHeaders", db: db) else { return [:] }
        var statement: OpaquePointer?
        let sql = """
            SELECT composerId, workspaceId, lastUpdatedAt, recency, isArchived, isSubagent, value
            FROM composerHeaders
            """
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw ReadError.unreadable }
        defer { sqlite3_finalize(statement) }
        var out: [String: Head] = [:]
        var step = sqlite3_step(statement)
        while step == SQLITE_ROW {
            let id = text(statement, 0)
            if !id.isEmpty {
                let updated = double(statement, 2) ?? double(statement, 3)
                out[id] = Head(
                    workspaceID: optional(text(statement, 1)),
                    recency: updated,
                    isSubagent: (double(statement, 5) ?? 0) != 0,
                    isArchived: (double(statement, 4) ?? 0) != 0,
                    json: json(text(statement, 6)))
            }
            step = sqlite3_step(statement)
        }
        guard step == SQLITE_DONE else { throw ReadError.unreadable }
        return out
    }

    static func details(db: OpaquePointer?) throws -> [String: [String: Any]] {
        guard tableExists("cursorDiskKV", db: db) else { return [:] }
        var statement: OpaquePointer?
        let sql = "SELECT key, value FROM cursorDiskKV WHERE key LIKE 'composerData:%'"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw ReadError.unreadable }
        defer { sqlite3_finalize(statement) }
        var out: [String: [String: Any]] = [:]
        var step = sqlite3_step(statement)
        while step == SQLITE_ROW {
            let key = text(statement, 0)
            let id = String(key.dropFirst("composerData:".count))
            if !id.isEmpty { out[id] = json(text(statement, 1)) }
            step = sqlite3_step(statement)
        }
        guard step == SQLITE_DONE else { throw ReadError.unreadable }
        return out
    }

    // MARK: - Shaping

    static func compose(id: String, head: Head?, detail: [String: Any]?) -> CursorComposer? {
        let facts = head?.json ?? [:]
        func fact(_ key: String) -> Any? { detail?[key] ?? facts[key] }
        // Cursor's timestamps are milliseconds since the epoch.
        let millis = (fact("lastUpdatedAt") as? Double)
            ?? (fact("createdAt") as? Double)
            ?? head?.recency
        let project = projectPath(fact("workspaceIdentifier")) ?? repoPath(fact("trackedGitRepos"))
        let usedTokens = (fact("contextTokensUsed") as? NSNumber)?.intValue
        let limitTokens = (fact("contextTokenLimit") as? NSNumber)?.intValue
        let composer = CursorComposer(
            id: id,
            name: nonEmpty(fact("name") as? String),
            subtitle: nonEmpty(fact("subtitle") as? String),
            project: project,
            branch: branch(fact("trackedGitRepos")),
            model: nonEmpty((fact("modelConfig") as? [String: Any])?["modelName"] as? String),
            contextTokens: usedTokens,
            contextWindow: limitTokens,
            status: nonEmpty(detail?["status"] as? String),
            blockingPendingActions: (fact("hasBlockingPendingActions") as? Bool) ?? false,
            isSubagent: head?.isSubagent ?? (fact("isSubagent") as? Bool) ?? false,
            isArchived: head?.isArchived ?? (fact("isArchived") as? Bool) ?? false,
            isDraft: (fact("isDraft") as? Bool) ?? false,
            isCloud: isCloud(fact("agentLocation"), id: id),
            updatedAt: millis.map { Date(timeIntervalSince1970: $0 / 1000) } ?? .distantPast)
        return composer
    }

    /// `workspaceIdentifier.uri.fsPath` — the folder the chat belongs to.
    /// `{"id":"empty-window"}` has no uri and means "no workspace".
    static func projectPath(_ value: Any?) -> String? {
        guard let identifier = value as? [String: Any],
              let uri = identifier["uri"] as? [String: Any] else { return nil }
        return nonEmpty(uri["fsPath"] as? String) ?? nonEmpty(uri["path"] as? String)
    }

    static func repoPath(_ value: Any?) -> String? {
        guard let repos = value as? [[String: Any]] else { return nil }
        return repos.compactMap { nonEmpty($0["repoPath"] as? String) }.first
    }

    /// The branch Cursor last saw for the tracked repo. Several branches can be
    /// recorded; the most recently interacted-with one is the live answer.
    static func branch(_ value: Any?) -> String? {
        guard let repos = value as? [[String: Any]] else { return nil }
        var best: (name: String, at: Double)?
        for repo in repos {
            for entry in (repo["branches"] as? [[String: Any]]) ?? [] {
                guard let name = nonEmpty(entry["branchName"] as? String) else { continue }
                let at = (entry["lastInteractionAt"] as? NSNumber)?.doubleValue ?? 0
                if best == nil || at > best!.at { best = (name, at) }
            }
        }
        return best?.name
    }

    /// Cursor records where an agent runs in `agentLocation.type` (`local` for
    /// this Mac). Cloud agents also carry a `bc-`-prefixed id, which is the
    /// fallback when the field is absent.
    static func isCloud(_ value: Any?, id: String) -> Bool {
        if let location = value as? [String: Any],
           let type = nonEmpty(location["type"] as? String) {
            return type != "local"
        }
        return id.hasPrefix("bc-")
    }

    // MARK: - SQLite helpers

    static func tableExists(_ name: String, db: OpaquePointer?) -> Bool {
        var statement: OpaquePointer?
        let sql = "SELECT 1 FROM sqlite_master WHERE type='table' AND name=?"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        guard sqlite3_bind_text(statement, 1, name, -1, transient) == SQLITE_OK else { return false }
        return sqlite3_step(statement) == SQLITE_ROW
    }

    static func json(_ raw: String) -> [String: Any] {
        guard !raw.isEmpty, let data = raw.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return [:] }
        return object
    }

    static func text(_ statement: OpaquePointer?, _ column: Int32) -> String {
        guard let pointer = sqlite3_column_text(statement, column) else { return "" }
        return String(cString: pointer)
    }

    static func double(_ statement: OpaquePointer?, _ column: Int32) -> Double? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL else { return nil }
        return sqlite3_column_double(statement, column)
    }

    static func optional(_ value: String) -> String? { value.isEmpty ? nil : value }

    static func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    private func signature() -> [String] {
        ["", "-wal"].map { suffix in
            guard let attributes = try? FileManager.default
                .attributesOfItem(atPath: database.path + suffix) else { return "missing" }
            let size = (attributes[.size] as? NSNumber)?.stringValue ?? "?"
            let modified = (attributes[.modificationDate] as? Date)?
                .timeIntervalSince1970.description ?? "?"
            return "\(size)/\(modified)"
        }
    }
}
