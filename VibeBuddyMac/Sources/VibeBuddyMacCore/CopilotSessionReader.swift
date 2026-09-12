import Foundation
import SQLite3
import VibeBuddyKit

/// Wake-compatible Copilot CLI history. No lifecycle events or remote actions.
/// Reads a private snapshot so even SQLite WAL/SHM bookkeeping never writes to
/// Copilot's directory. A changed source during copying is retried next poll.
public struct CopilotSessionReader: Sendable {
    public let database: URL
    private var stamp: [String]?
    public init(database: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".copilot/session-store.db")) { self.database = database }

    public struct Record: Equatable, Sendable {
        public var session: AgentSession
        public var output: RecentOutput
    }
    public enum ReadError: Error { case unreadable, changedDuringRead }

    /// nil means unchanged; an empty array means a successfully read empty store.
    public mutating func refresh() throws -> [Record]? {
        let before = signature()
        guard before != stamp else { return nil }
        stamp = nil // failed reads must be retried, including return to a prior signature
        guard FileManager.default.fileExists(atPath: database.path) else {
            stamp = before
            return []
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vibebuddy-copilot-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let copy = directory.appendingPathComponent("history.sqlite")
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
        var statement: OpaquePointer?
        let sql = """
            SELECT s.id, s.cwd, s.branch, s.summary, s.created_at, s.updated_at,
                   (SELECT substr(t.user_message,1,220) FROM turns t
                    WHERE t.session_id=s.id AND trim(COALESCE(t.user_message,''))<>''
                    ORDER BY t.turn_index LIMIT 1)
            FROM sessions s WHERE EXISTS (SELECT 1 FROM turns t WHERE t.session_id=s.id)
            ORDER BY s.updated_at DESC, s.id
            """
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw ReadError.unreadable
        }
        defer { sqlite3_finalize(statement) }
        var records: [Record] = []
        var step = sqlite3_step(statement)
        while step == SQLITE_ROW {
            let nativeID = text(statement, 0)
            if !nativeID.isEmpty {
                let id = "copilot:\(nativeID)"
                let updated = date(text(statement, 5)) ?? date(text(statement, 4)) ?? .distantPast
                let summary = String(text(statement, 3).trimmingCharacters(in: .whitespacesAndNewlines).prefix(220))
                var session = AgentSession(id: id, agent: .copilot, project: text(statement, 1),
                    branch: optional(text(statement, 2)), status: .done,
                    summary: optional(summary),
                    name: optional(summary) ?? optional(text(statement, 6)),
                    statusSince: updated, updatedAt: updated)
                // .done is the existing wire representation for a quiet row;
                // historyOnly makes clear that no live status was established.
                session.historyOnly = true
                records.append(Record(session: session,
                    output: try output(db: db, nativeID: nativeID, id: id, updated: updated)))
            }
            step = sqlite3_step(statement)
        }
        guard step == SQLITE_DONE else { throw ReadError.unreadable }
        stamp = before
        return records
    }

    private func output(db: OpaquePointer?, nativeID: String, id: String, updated: Date) throws -> RecentOutput {
        var statement: OpaquePointer?
        // Fetch one extra turn to report truncation, bounding text in SQLite.
        let sql = "SELECT substr(user_message,1,601), substr(assistant_response,1,601) FROM turns WHERE session_id=? ORDER BY turn_index DESC LIMIT 7"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw ReadError.unreadable }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        guard sqlite3_bind_text(statement, 1, nativeID, -1, transient) == SQLITE_OK else { throw ReadError.unreadable }
        var turns: [[RecentOutputEntry]] = []
        var truncated = false
        var step = sqlite3_step(statement)
        while step == SQLITE_ROW {
            var entries: [RecentOutputEntry] = []
            for (column, role) in [(Int32(0), "user"), (Int32(1), "assistant")] {
                let value = text(statement, column)
                if value.count > 600 { truncated = true }
                if !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    entries.append(.init(role: role, text: String(value.prefix(600))))
                }
            }
            turns.append(entries)
            step = sqlite3_step(statement)
        }
        guard step == SQLITE_DONE else { throw ReadError.unreadable }
        let entries = turns.reversed().flatMap { $0 }
        return RecentOutput(sessionId: id, source: .transcript, updatedAt: updated,
            truncated: truncated || turns.count > 6 || entries.count > 12,
            entries: Array(entries.suffix(12)))
    }

    private func signature() -> [String] {
        ["", "-wal"].map { suffix in
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: database.path + suffix) else { return "missing" }
            return "\(attrs[.systemFileNumber] ?? ""):\(attrs[.size] ?? ""):\((attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)"
        }
    }
    private func text(_ statement: OpaquePointer?, _ column: Int32) -> String {
        sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
    }
    private func optional(_ text: String) -> String? { text.isEmpty ? nil : text }
    private func date(_ value: String) -> Date? {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: value) { return date }
        if let date = ISO8601DateFormatter().date(from: value) { return date }
        let sql = DateFormatter()
        sql.locale = Locale(identifier: "en_US_POSIX")
        sql.timeZone = TimeZone(secondsFromGMT: 0)
        sql.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return sql.date(from: value)
    }
}
