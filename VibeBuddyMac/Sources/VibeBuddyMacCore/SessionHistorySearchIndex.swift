import Foundation
import SQLite3

/// Derived, rebuildable message index. Confined to SessionHistoryRepository's actor.
/// User preferences and original transcripts never live in this database.
final class SessionHistorySearchIndex {
    private var db: OpaquePointer?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    private struct Failure: LocalizedError {
        let detail: String
        var errorDescription: String? { "History search index: \(detail). Rebuild the index to retry." }
    }

    init(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let path = directory.appendingPathComponent("search.sqlite").path
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
            let detail = db.map { String(cString: sqlite3_errmsg($0)) } ?? "Cannot open database"
            sqlite3_close(db); db = nil
            throw Failure(detail: detail)
        }
        do {
            sqlite3_busy_timeout(db, 1000)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
            try execute("""
                CREATE TABLE IF NOT EXISTS sources(path TEXT PRIMARY KEY, stamp TEXT NOT NULL);
                CREATE TABLE IF NOT EXISTS messages(id INTEGER PRIMARY KEY, path TEXT NOT NULL,
                    message_id TEXT NOT NULL, text TEXT NOT NULL, folded TEXT NOT NULL);
                CREATE INDEX IF NOT EXISTS messages_path ON messages(path);
                CREATE VIRTUAL TABLE IF NOT EXISTS messages_fts USING fts5(folded,
                    content='messages', content_rowid='id', tokenize='trigram');
                CREATE TRIGGER IF NOT EXISTS messages_insert AFTER INSERT ON messages BEGIN
                    INSERT INTO messages_fts(rowid, folded) VALUES(new.id, new.folded);
                END;
                CREATE TRIGGER IF NOT EXISTS messages_delete AFTER DELETE ON messages BEGIN
                    INSERT INTO messages_fts(messages_fts, rowid, folded) VALUES('delete', old.id, old.folded);
                END;
                """)
        } catch { sqlite3_close(db); db = nil; throw error }
    }
    deinit { sqlite3_close(db) }

    func isCurrent(path: String, stamp: String) throws -> Bool {
        let statement = try prepare("SELECT stamp FROM sources WHERE path=?", [path])
        defer { sqlite3_finalize(statement) }
        let code = sqlite3_step(statement)
        guard code == SQLITE_ROW || code == SQLITE_DONE else { throw failure() }
        return code == SQLITE_ROW && text(statement, 0) == stamp
    }

    func replace(_ session: SessionHistorySession, stamp: String) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            try run("DELETE FROM messages WHERE path=?", [session.sourcePath])
            let insert = try prepare("INSERT INTO messages(path,message_id,text,folded) VALUES(?,?,?,?)")
            defer { sqlite3_finalize(insert) }
            for message in session.messages {
                try Task.checkCancellation()
                sqlite3_reset(insert); sqlite3_clear_bindings(insert)
                try bind(insert, [session.sourcePath, message.id, message.text, Self.fold(message.text)])
                guard sqlite3_step(insert) == SQLITE_DONE else { throw failure() }
            }
            try run("INSERT OR REPLACE INTO sources(path,stamp) VALUES(?,?)", [session.sourcePath, stamp])
            try execute("COMMIT")
        } catch { try? execute("ROLLBACK"); throw error }
    }

    /// Literal substring semantics, including punctuation, quotes, CJK and short queries.
    /// Trigram narrows candidates for >=3 scalars; instr handles shorter text exactly.
    func search(_ query: String, sessions: [SessionHistorySession], limit: Int) throws -> [SessionHistorySearchResult] {
        let needle = Self.fold(query)
        guard !needle.isEmpty else { return [] }
        let allowed = Dictionary(uniqueKeysWithValues: sessions.map { ($0.sourcePath, $0) })
        let indexed = needle.unicodeScalars.count >= 3 && !needle.contains("\0")
        let sql = indexed
            ? "SELECT m.path,m.message_id,m.text FROM messages_fts JOIN messages m ON m.id=messages_fts.rowid WHERE messages_fts MATCH ? ORDER BY bm25(messages_fts),m.id"
            : "SELECT path,message_id,text FROM messages WHERE instr(folded,?)>0 ORDER BY id"
        let expression = indexed ? "\"" + needle.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : needle
        let statement = try prepare(sql, [expression])
        defer { sqlite3_finalize(statement) }
        var results: [SessionHistorySearchResult] = []
        while true {
            try Task.checkCancellation()
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { break }
            guard code == SQLITE_ROW else { throw failure() }
            guard let session = allowed[text(statement, 0)] else { continue }
            let body = text(statement, 2)
            guard let match = body.range(of: query, options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX")) else { continue }
            let start = body.index(match.lowerBound, offsetBy: -70, limitedBy: body.startIndex) ?? body.startIndex
            let end = body.index(match.upperBound, offsetBy: 130, limitedBy: body.endIndex) ?? body.endIndex
            results.append(SessionHistorySearchResult(sessionID: session.id, messageID: text(statement, 1), excerpt: String(body[start..<end])))
            if results.count >= limit { break }
        }
        return results
    }

    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
    private func failure() -> Failure { Failure(detail: String(cString: sqlite3_errmsg(db))) }
    private func execute(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw failure() }
    }
    private func prepare(_ sql: String, _ values: [String] = []) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw failure() }
        do { try bind(statement, values) } catch { sqlite3_finalize(statement); throw error }
        return statement
    }
    private func bind(_ statement: OpaquePointer, _ values: [String]) throws {
        for (index, value) in values.enumerated() {
            guard sqlite3_bind_text(statement, Int32(index + 1), value, Int32(value.utf8.count), transient) == SQLITE_OK else { throw failure() }
        }
    }
    private func run(_ sql: String, _ values: [String]) throws {
        let statement = try prepare(sql, values)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw failure() }
    }
    private func text(_ statement: OpaquePointer, _ column: Int32) -> String {
        guard let bytes = sqlite3_column_text(statement, column) else { return "" }
        return String(decoding: UnsafeBufferPointer(start: bytes, count: Int(sqlite3_column_bytes(statement, column))), as: UTF8.self)
    }
}
