import Foundation
import SQLite3

/// Read-only native CLI evidence. Enum/field numbers were verified against the
/// shipped agy 1.2.16 protobuf descriptors, not guessed from step DONE values.
/// Unknown schema/enum values are observation uncertainty, never success.
enum AntigravityNative {
    struct State {
        var lastIndex: Int
        var lastType: Int
        var lastStatus: Int
        var waiting: Bool
        var reason: Int?
        var executionID: String?
        var error: String?
        var terminalIndex: Int?
    }
    static func state(database: URL, sessionID: String) -> State? {
        guard let snapshot = snapshot(database) else { return nil }
        defer { try? FileManager.default.removeItem(at: snapshot.deletingLastPathComponent()) }
        var db: OpaquePointer?
        // SQLite may recover WAL bookkeeping only inside our private copy.
        guard sqlite3_open_v2(snapshot.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            sqlite3_close(db); return nil
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 100)
        guard sqlite3_exec(db, "BEGIN", nil, nil, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_exec(db, "ROLLBACK", nil, nil, nil) }
        func query(_ sql: String) -> OpaquePointer? {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
            return statement
        }
        guard let identity = query("SELECT cascade_id FROM trajectory_meta LIMIT 1") else { return nil }
        defer { sqlite3_finalize(identity) }
        guard sqlite3_step(identity) == SQLITE_ROW, let value = sqlite3_column_text(identity, 0),
              String(cString: value) == sessionID else { return nil }
        guard let steps = query("SELECT idx,step_type,status FROM steps ORDER BY idx DESC LIMIT 1") else { return nil }
        defer { sqlite3_finalize(steps) }
        guard sqlite3_step(steps) == SQLITE_ROW else { return nil }
        var result = State(lastIndex: Int(sqlite3_column_int(steps, 0)), lastType: Int(sqlite3_column_int(steps, 1)),
                           lastStatus: Int(sqlite3_column_int(steps, 2)), waiting: false)
        if let pending = query("SELECT 1 FROM steps WHERE status=9 LIMIT 1") {
            result.waiting = sqlite3_step(pending) == SQLITE_ROW
            sqlite3_finalize(pending)
        }
        if let executor = query("SELECT data FROM executor_metadata ORDER BY idx DESC LIMIT 1") {
            defer { sqlite3_finalize(executor) }
            if sqlite3_step(executor) == SQLITE_ROW, let bytes = sqlite3_column_blob(executor, 0) {
                let count = Int(sqlite3_column_bytes(executor, 0))
                guard count <= 4 * 1024 * 1024 else { return nil }
                if let fields = wireFields(Data(bytes: bytes, count: count)) {
                    result.reason = fields.numbers[1]
                    result.terminalIndex = fields.numbers[3] ?? 0
                    result.executionID = fields.strings[9]
                    result.error = fields.strings[12]
                }
            }
        }
        return result
    }

    /// Only the top-level scalar fields of ExecutorMetadata are needed. Skip
    /// bounded unknown fields; never decode or retain its credentials/config.
    private static func wireFields(_ data: Data) -> (numbers: [Int: Int], strings: [Int: String])? {
        let bytes = Array(data); var offset = 0
        var numbers: [Int: Int] = [:]; var strings: [Int: String] = [:]
        func varint() -> UInt64? {
            var result: UInt64 = 0
            for shift in stride(from: 0, to: 64, by: 7) {
                guard offset < bytes.count else { return nil }
                let byte = bytes[offset]; offset += 1
                if shift == 63 && byte > 1 { return nil }
                result |= UInt64(byte & 127) << shift
                if byte < 128 { return result }
            }
            return nil
        }
        while offset < bytes.count {
            guard let tag = varint(), tag > 0 else { return nil }
            let field = Int(tag >> 3)
            switch tag & 7 {
            case 0:
                guard let value = varint(), value <= UInt64(Int.max) else { return nil }
                if [1, 3].contains(field) { numbers[field] = Int(value) }
            case 1: offset += 8
            case 5: offset += 4
            case 2:
                guard let length = varint(), length <= UInt64(bytes.count - offset) else { return nil }
                let end = offset + Int(length)
                if [9, 12].contains(field) { strings[field] = String(bytes: bytes[offset..<end], encoding: .utf8) }
                offset = end
            default: return nil
            }
            guard offset <= bytes.count else { return nil }
        }
        return (numbers, strings)
    }

    static func summary(database: URL, sessionID: String) -> (cwd: String?, title: String?, fullyIdle: Bool)? {
        guard let snapshot = snapshot(database) else { return nil }
        defer { try? FileManager.default.removeItem(at: snapshot.deletingLastPathComponent()) }
        var db: OpaquePointer?
        // SQLite may recover WAL bookkeeping only inside our private copy.
        guard sqlite3_open_v2(snapshot.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else { sqlite3_close(db); return nil }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 100)
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT workspace_uris,title,not_fully_idle FROM conversation_summaries WHERE conversation_id=?", -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        _ = sessionID.withCString { sqlite3_bind_text(statement, 1, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        let raw = sqlite3_column_text(statement, 0).map { String(cString: $0) } ?? ""
        let paths = raw.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String] } ?? []
        let cwd = paths.first.flatMap { URL(string: $0) }.flatMap { $0.isFileURL ? $0.path : nil }
        let title = sqlite3_column_text(statement, 1).map { String(cString: $0) }
        guard sqlite3_column_type(statement, 2) == SQLITE_INTEGER else { return nil }
        let notFullyIdle = sqlite3_column_int(statement, 2)
        guard notFullyIdle == 0 || notFullyIdle == 1 else { return nil }
        return (cwd, title, notFullyIdle == 0)
    }

    /// Match the existing Cursor/Copilot source boundary: copy main+WAL to
    /// private scratch so SQLite never creates SHM beside the user's files.
    private static func snapshot(_ database: URL) -> URL? {
        let fm = FileManager.default
        let directory = fm.temporaryDirectory.appendingPathComponent("vibebuddy-antigravity-" + UUID().uuidString)
        let copy = directory.appendingPathComponent("conversation.db")
        let paths = [database, URL(fileURLWithPath: database.path + "-wal")]
        let before = paths.map { SessionTranscriptReader.sourceRevision($0) }
        guard before[0] != nil else { return nil }
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            for (index, source) in paths.enumerated() where before[index] != nil {
                let size = try source.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size <= 64 * 1024 * 1024 else { throw CocoaError(.fileReadTooLarge) }
                try fm.copyItem(at: source, to: index == 0 ? copy : URL(fileURLWithPath: copy.path + "-wal"))
            }
            guard paths.map({ SessionTranscriptReader.sourceRevision($0) }) == before else { throw CocoaError(.fileReadUnknown) }
            return copy
        } catch { try? fm.removeItem(at: directory); return nil }
    }

    static func rows(_ file: URL) -> [[String: Any]]? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 32 * 1024 * 1024 + 1), data.count <= 32 * 1024 * 1024 else { return nil }
        return data.split(separator: 10).compactMap { try? JSONSerialization.jsonObject(with: Data($0)) as? [String: Any] }
    }

    static func question(_ call: [String: Any]) -> String? {
        let args = call["args"] as? [String: Any] ?? [:]
        var value = args["questions"]
        if let text = value as? String, let data = text.data(using: .utf8) { value = try? JSONSerialization.jsonObject(with: data) }
        return (value as? [[String: Any]])?.compactMap { $0["question"] as? String }.joined(separator: "\n")
    }
}
