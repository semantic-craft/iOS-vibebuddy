import Foundation
import Darwin

/// What a hosted ACP session keeps so a later host can load it again:
/// metadata only — the agent owns prompts, history and authentication. One
/// private file per session (0600 in a 0700 directory), kept 30 days and at
/// most 100 records.
protocol ACPRecoveryRecord: Codable, Sendable {
    var sessionID: String { get }
    var createdAt: Date { get }
    var origin: String { get }
    /// The `origin` this host writes; any other record is ignored.
    static var expectedOrigin: String { get }
}

extension ACPRecoveryRecord {
    var filename: String { Data(sessionID.utf8).base64EncodedString().replacingOccurrences(of: "/", with: "_") }

    func save(in directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let target = directory.appendingPathComponent(filename + ".json")
        let temporary = directory.appendingPathComponent(UUID().uuidString + ".tmp")
        let data = try JSONEncoder().encode(self)
        guard FileManager.default.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else { throw CocoaError(.fileWriteUnknown) }
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard rename(temporary.path, target.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
        _ = Self.read(in: directory)
    }
    static func read(in directory: URL, now: Date = Date()) -> [Self] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        let entries = files.filter { $0.pathExtension == "json" }.compactMap { url -> (URL, Self)? in
            guard let data = try? Data(contentsOf: url), let value = try? JSONDecoder().decode(Self.self, from: data),
                  value.origin == Self.expectedOrigin, !value.sessionID.isEmpty else { return nil }
            return (url, value)
        }.sorted { $0.1.createdAt > $1.1.createdAt }
        var result: [Self] = []
        for (url, value) in entries {
            if now.timeIntervalSince(value.createdAt) <= 30 * 86400 && result.count < 100 { result.append(value) }
            else { try? FileManager.default.removeItem(at: url) }
        }
        return result
    }

    static func remove(_ sessionID: String, in directory: URL) {
        let name = Data(sessionID.utf8).base64EncodedString().replacingOccurrences(of: "/", with: "_")
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(name + ".json"))
    }
}

/// Metadata only: Cursor owns prompts, history and authentication.
struct CursorACPRecovery: ACPRecoveryRecord {
    let sessionID: String
    let cwd: String
    let options: CursorLaunchOptions
    let createdAt: Date
    var updatedAt: Date? = nil
    let origin: String
    let unavailable: String?

    static let expectedOrigin = "vibebuddy-acp"

    static var directory: URL {
        let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        return URL(fileURLWithPath: home).appendingPathComponent("Library/Application Support/vibebuddy/cursor-acp")
    }
}

/// Never unlink lock files: replacing their inode defeats cross-process exclusion.
final class CursorACPLease: @unchecked Sendable {
    private let descriptor: Int32
    init<Record: ACPRecoveryRecord>(directory: URL, record: Record, agent: String = "Cursor") throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        descriptor = open(directory.appendingPathComponent(record.filename + ".lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(descriptor)
            throw NSError(domain: "CursorACP", code: 1, userInfo: [NSLocalizedDescriptionKey: "Another host is driving this \(agent) session"])
        }
        var bytes = [UInt8](repeating: 0, count: 512)
        let count = pread(descriptor, &bytes, bytes.count, 0)
        if count > 0, let previous = try? JSONDecoder().decode(ProcessIdentity.self, from: Data(bytes.prefix(count))),
           previous.isStillRunning {
            flock(descriptor, LOCK_UN)
            Darwin.close(descriptor)
            throw NSError(domain: "CursorACP", code: 3, userInfo: [NSLocalizedDescriptionKey: "Previous \(agent) process is still running"])
        }
    }
    private struct ProcessIdentity: Codable {
        let pid: Int32
        let seconds: UInt64
        let microseconds: UInt64
        static func read(_ pid: Int32) -> Self? {
            var info = proc_bsdinfo()
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) == MemoryLayout<proc_bsdinfo>.size else { return nil }
            return Self(pid: pid, seconds: info.pbi_start_tvsec, microseconds: info.pbi_start_tvusec)
        }
        var isStillRunning: Bool {
            guard let current = Self.read(pid) else { return kill(pid, 0) == 0 }
            return current.seconds == seconds && current.microseconds == microseconds
        }
    }
    func recordProcess(_ process: Process?) throws {
        guard let process else { return } // Pipe-based test clients have no process.
        guard let identity = ProcessIdentity.read(process.processIdentifier) else {
            throw NSError(domain: "CursorACP", code: 4, userInfo: [NSLocalizedDescriptionKey: "Could not identify the Cursor process for recovery"])
        }
        let bytes = try JSONEncoder().encode(identity)
        guard ftruncate(descriptor, 0) == 0,
              bytes.withUnsafeBytes({ pwrite(descriptor, $0.baseAddress, $0.count, 0) }) == bytes.count,
              fsync(descriptor) == 0 else { throw CocoaError(.fileWriteUnknown) }
    }
    deinit { ftruncate(descriptor, 0); fsync(descriptor); flock(descriptor, LOCK_UN); Darwin.close(descriptor) }
}
