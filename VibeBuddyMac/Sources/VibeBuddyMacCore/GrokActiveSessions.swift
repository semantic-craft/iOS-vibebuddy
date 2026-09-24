import Darwin
import Foundation

/// Grok Build's cross-process session registry, `<grok home>/active_sessions.json`
/// (`[cli] session_registry`, on by default): one entry per open `grok` process —
/// `session_id`, `pid`, `cwd`, `opened_at`. Grok adds an entry when a session
/// opens and removes it when the process exits cleanly, so a closed terminal
/// leaves the list even when its `session_end` hook never reached the daemon.
/// A process killed outright keeps its entry, so every entry's pid is checked
/// too, against its start time so a reused pid does not keep a dead session
/// alive (grok 1.0.41, measured 2026-09-24).
///
/// The file is re-read only when its modification time or size changes.
struct GrokActiveSessions {
    struct Entry: Decodable, Equatable {
        let sessionID: String
        let pid: Int32
        let openedAt: Date?

        enum CodingKeys: String, CodingKey {
            case sessionID = "session_id", pid, openedAt = "opened_at"
        }

        init(sessionID: String, pid: Int32, openedAt: Date?) {
            self.sessionID = sessionID
            self.pid = pid
            self.openedAt = openedAt
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            sessionID = try container.decode(String.self, forKey: .sessionID)
            pid = try container.decode(Int32.self, forKey: .pid)
            openedAt = (try? container.decode(String.self, forKey: .openedAt)).flatMap(GrokActiveSessions.date)
        }
    }

    let url: URL
    /// Whether a pid still belongs to the process that registered the entry.
    var isRunning: (Entry) -> Bool = GrokActiveSessions.processIsRunning

    private var stamp: (Date, Int)?
    private var entries: [Entry] = []

    init(grokHome: URL) {
        url = grokHome.appendingPathComponent("active_sessions.json")
    }

    /// Session ids with a live `grok` process, or nil when the registry is
    /// absent or unreadable — then it says nothing either way.
    mutating func liveSessionIDs() -> Set<String>? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let modified = attributes[.modificationDate] as? Date,
              let size = (attributes[.size] as? NSNumber)?.intValue else {
            stamp = nil
            entries = []
            return nil
        }
        if stamp.map({ $0.0 != modified || $0.1 != size }) ?? true {
            guard let data = try? Data(contentsOf: url),
                  let decoded = try? JSONDecoder().decode([Entry].self, from: data) else {
                // Caught mid-write, or a shape this build does not know.
                stamp = nil
                entries = []
                return nil
            }
            stamp = (modified, size)
            entries = decoded
        }
        return Set(entries.filter(isRunning).map(\.sessionID))
    }

    /// Alive, and started no later than it registered (a second of slack for
    /// clock rounding). Without a start time, `kill(pid, 0)` decides.
    static func processIsRunning(_ entry: Entry) -> Bool {
        guard entry.pid > 0 else { return false }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(entry.pid, PROC_PIDTBSDINFO, 0, &info, size) == size else {
            return kill(entry.pid, 0) == 0 || errno == EPERM
        }
        guard let openedAt = entry.openedAt else { return true }
        let started = Date(timeIntervalSince1970: TimeInterval(info.pbi_start_tvsec)
            + TimeInterval(info.pbi_start_tvusec) / 1_000_000)
        return started <= openedAt.addingTimeInterval(1)
    }

    /// `2026-09-24T07:44:40.200616Z` — Grok writes microseconds.
    static func date(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }
}
