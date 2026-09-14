import Foundation

/// Where sessions have run, kept across restarts (ADR-0023 amendment, ticket
/// handoff-continue-hardening/01): the directories a new task may start in
/// and, per session, the checkout it was actually observed in. The lifecycle
/// journal still stores no full path; this file exists only to answer "where
/// may a task start" and "where are the handoffs" right after a launch, and
/// to give a journal-restored session its own checkout back — never a guess
/// from a matching folder name.
///
/// Owner-only JSON, atomic writes, seven-day retention; unavailable storage
/// degrades to memory for this process only.
struct RecentDirectories {
    struct SessionCheckout: Codable, Equatable, Sendable {
        var path: String
        var seenAt: Date
    }
    private struct File: Codable {
        var directories: [String: Date]
        var sessions: [String: SessionCheckout]
    }

    static let directoryLimit = 50
    static let sessionLimit = 500
    static let retention: TimeInterval = 7 * 86_400

    let url: URL?
    private(set) var directories: [String: Date] = [:]
    private(set) var sessions: [String: SessionCheckout] = [:]
    private var available = true

    init(url: URL?, now: Date = Date()) {
        self.url = url
        guard let url else { return }
        do {
            let file = try JSONDecoder().decode(File.self, from: Data(contentsOf: url))
            let cutoff = now.addingTimeInterval(-Self.retention)
            directories = file.directories.filter { $0.value >= cutoff }
            sessions = file.sessions.filter { $0.value.seenAt >= cutoff }
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
        } catch {
            available = false
        }
    }

    /// Newest first.
    var recent: [String] { directories.sorted { $0.value > $1.value }.map(\.key) }
    func isKnown(_ path: String) -> Bool { directories[path] != nil }
    func checkout(of sessionID: String) -> String? { sessions[sessionID]?.path }

    /// One observation: a session ran in `cwd` at `date`.
    mutating func remember(_ cwd: String?, sessionID: String?, at date: Date) {
        guard let cwd, cwd.hasPrefix("/"), !cwd.isEmpty else { return }
        directories[cwd] = date
        while directories.count > Self.directoryLimit, let oldest = directories.min(by: { $0.value < $1.value }) {
            directories.removeValue(forKey: oldest.key)
        }
        if let sessionID, !sessionID.isEmpty {
            sessions[sessionID] = SessionCheckout(path: cwd, seenAt: date)
            while sessions.count > Self.sessionLimit, let oldest = sessions.min(by: { $0.value.seenAt < $1.value.seenAt }) {
                sessions.removeValue(forKey: oldest.key)
            }
        }
        save(now: date)
    }

    private func save(now: Date) {
        guard let url, available else { return }
        let cutoff = now.addingTimeInterval(-Self.retention)
        let file = File(directories: directories.filter { $0.value >= cutoff },
                        sessions: sessions.filter { $0.value.seenAt >= cutoff })
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let data = try JSONEncoder().encode(file)
            try data.write(to: url, options: [.atomic, .completeFileProtection])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            // Memory keeps this process honest; the next launch starts from the last good file.
        }
    }
}
