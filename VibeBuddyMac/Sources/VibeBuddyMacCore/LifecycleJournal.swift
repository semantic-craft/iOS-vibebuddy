import Foundation
import Darwin
import VibeBuddyKit

/// One privacy-minimized lifecycle transition. The journal deliberately stores
/// only normalized reducer facts: never raw hook JSON, prompts, summaries,
/// reasoning, transcript paths, tool names, tool input, or tool output.
public struct LifecycleJournalEntry: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let sessionID: String
    public let agent: AgentKind
    public let event: String
    public let source: ObservationSource
    public let timestamp: Date
    public let status: SessionStatus?
    public let waitKind: WaitKind?
    /// The project label the row was showing — the working directory's last
    /// path component only, never the full path, and never longer than
    /// `maxProjectBytes` — so a restored session has a name instead of a
    /// placeholder until its next event arrives. Optional so journals written
    /// before the field existed still decode.
    public let project: String?
    public let completionID: String?
    public let hasUnreadCompletion: Bool?
    public let statusSince: Date?
    public let failed: Bool?

    /// A hook may hand the reducer an arbitrarily long slash-free `cwd`, which
    /// becomes the whole project label; persisting that unbounded would let one
    /// event blow the journal past its practical byte bound. Labels are cut here.
    public static let maxProjectBytes = 128

    public init(
        id: UUID = UUID(),
        sessionID: String,
        agent: AgentKind,
        event: String,
        source: ObservationSource,
        timestamp: Date,
        status: SessionStatus?,
        waitKind: WaitKind?,
        project: String? = nil,
        completionID: String? = nil,
        hasUnreadCompletion: Bool? = nil,
        statusSince: Date? = nil,
        failed: Bool? = nil
    ) {
        self.id = id
        self.sessionID = sessionID
        self.agent = agent
        self.event = event
        self.source = source
        self.timestamp = timestamp
        self.status = status
        self.waitKind = waitKind
        self.project = project.map(Self.boundedProject)
        self.completionID = completionID
        self.hasUnreadCompletion = hasUnreadCompletion
        self.statusSince = statusSince
        self.failed = failed
    }

    /// The label cut to `maxProjectBytes` of UTF-8 on a character boundary.
    static func boundedProject(_ label: String) -> String {
        guard label.utf8.count > maxProjectBytes else { return label }
        var out = ""
        for ch in label {
            if (out + String(ch)).utf8.count > maxProjectBytes { break }
            out.append(ch)
        }
        return out
    }
}
public enum LifecycleJournalLocation {
    public static func defaultURL(
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        home.appendingPathComponent("Library/Application Support/vibebuddy/lifecycle-journal.json")
    }
}

/// A small, atomically replaced local journal. Persistence is best-effort:
/// unreadable/corrupt/future-schema data starts empty and every write failure is
/// contained here so lifecycle monitoring keeps running.
struct LifecycleJournal {
    static let maxEntries = 250
    static let retention: TimeInterval = 7 * 24 * 60 * 60

    private struct Envelope: Codable {
        let schemaVersion: Int
        let entries: [LifecycleJournalEntry]
        // Current business state is not diagnostic history: event count/age
        // pruning must never forget which completion a wrist already read.
        let completions: [String: LifecycleJournalEntry]?
    }

    let url: URL
    private let capacity: Int
    private let retention: TimeInterval
    private(set) var entries: [LifecycleJournalEntry]
    private var completions: [String: LifecycleJournalEntry] = [:]

    init(
        url: URL,
        capacity: Int = LifecycleJournal.maxEntries,
        retention: TimeInterval = LifecycleJournal.retention,
        now: Date = Date()
    ) {
        self.url = url
        self.capacity = max(1, capacity)
        self.retention = max(0, retention)

        guard let data = try? Data(contentsOf: url),
              let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
              envelope.schemaVersion == 1 else {
            entries = []
            return
        }
        completions = envelope.completions ?? [:]
        entries = Self.pruned(
            envelope.entries,
            capacity: self.capacity,
            retention: self.retention,
            now: now
        )
    }

    @discardableResult
    mutating func append(_ entry: LifecycleJournalEntry, now: Date) -> Bool {
        if entry.status == .done, entry.completionID != nil {
            completions[entry.sessionID] = entry
        } else {
            completions.removeValue(forKey: entry.sessionID)
        }
        entries.append(entry)
        entries = Self.pruned(entries, capacity: capacity, retention: retention, now: now)
        return persistBestEffort()
    }

    func recent(limit: Int) -> [LifecycleJournalEntry] {
        Array(entries.suffix(max(0, limit)).reversed())
    }

    /// Active/wait recovery has an age limit. Current completed rounds survive
    /// independently until a new round or session removal retires them.
    func restorableSessions(now: Date, meaningfulFor: TimeInterval) -> [AgentSession] {
        var latest: [String: LifecycleJournalEntry] = [:]
        for entry in entries { latest[entry.sessionID] = entry }
        for (id, entry) in completions { latest[id] = entry }
        return latest.values.compactMap { entry in
            guard let status = entry.status,
                  (status == .working || status == .needsResponse || entry.completionID != nil),
                  (entry.completionID != nil || now.timeIntervalSince(entry.timestamp) <= max(0, meaningfulFor))
            else { return nil }
            return AgentSession(
                id: entry.sessionID,
                agent: entry.agent,
                project: entry.project ?? "—",
                status: status,
                waitKind: entry.waitKind,
                failed: entry.failed,
                hasUnreadCompletion: entry.hasUnreadCompletion ?? false,
                completionID: entry.completionID,
                observations: [ObservationEvidence(
                    source: .recovery,
                    lastObservedAt: entry.timestamp,
                    health: .healthy
                )],
                statusSince: entry.statusSince ?? entry.timestamp,
                updatedAt: entry.timestamp
            )
        }
    }

    /// Returns false when old on-disk data could not be removed. Failed clears
    /// keep the in-memory entries so the UI accurately shows that data remains
    /// and can offer the clear action again after permissions are repaired.
    mutating func clear() -> Bool {
        // Clear diagnostic history, not the active completion contract.
        if !completions.isEmpty {
            let previous = entries
            entries.removeAll()
            if persistBestEffort() { return true }
            entries = previous
            return false
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            entries.removeAll()
            return true
        }
        do {
            try FileManager.default.removeItem(at: url)
            entries.removeAll()
            return true
        } catch {
            return false
        }
    }

    private static func pruned(
        _ entries: [LifecycleJournalEntry],
        capacity: Int,
        retention: TimeInterval,
        now: Date
    ) -> [LifecycleJournalEntry] {
        let cutoff = now.addingTimeInterval(-retention)
        let retained = entries.filter { $0.timestamp >= cutoff }
        return Array(retained.suffix(capacity))
    }

    private func persistBestEffort() -> Bool {
        do {
            let directory = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: directory.path
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(Envelope(schemaVersion: 1, entries: entries, completions: completions))
            try publishSecurely(data, in: directory)
            return true
        } catch {
            // Hook processing remains fail-open; explicit acknowledgement can
            // use this result to avoid reporting a read it cannot recover.
            return false
        }
    }

    /// Write into an owner-only sibling and publish it only after the bytes are
    /// durable and the mode has been verified. No journal contents are ever
    /// placed in a default-permission file, even briefly.
    private func publishSecurely(_ data: Data, in directory: URL) throws {
        let stagingURL = directory.appendingPathComponent(
            ".\(url.lastPathComponent).\(UUID().uuidString).tmp"
        )
        let descriptor = Darwin.open(
            stagingURL.path,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            mode_t(0o600)
        )
        guard descriptor >= 0 else { throw Self.currentPOSIXError() }

        var isOpen = true
        var stagingExists = true
        defer {
            if isOpen { _ = Darwin.close(descriptor) }
            if stagingExists { _ = stagingURL.path.withCString(Darwin.unlink) }
        }

        guard Darwin.fchmod(descriptor, mode_t(0o600)) == 0 else {
            throw Self.currentPOSIXError()
        }
        try Self.requireOwnerOnly(descriptor)
        try Self.writeAll(data, to: descriptor)
        guard Darwin.fsync(descriptor) == 0 else { throw Self.currentPOSIXError() }
        try Self.requireOwnerOnly(descriptor)
        let closeResult = Darwin.close(descriptor)
        isOpen = false
        guard closeResult == 0 else { throw Self.currentPOSIXError() }

        guard stagingURL.path.withCString({ stagingPath in
            url.path.withCString { destinationPath in
                Darwin.rename(stagingPath, destinationPath)
            }
        }) == 0 else {
            throw Self.currentPOSIXError()
        }
        stagingExists = false
    }

    private static func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { buffer in
            guard var cursor = buffer.baseAddress else { return }
            var remaining = buffer.count
            while remaining > 0 {
                let written = Darwin.write(descriptor, cursor, remaining)
                if written < 0, errno == EINTR { continue }
                guard written > 0 else { throw currentPOSIXError() }
                cursor = cursor.advanced(by: written)
                remaining -= written
            }
        }
    }

    private static func requireOwnerOnly(_ descriptor: Int32) throws {
        var status = stat()
        guard Darwin.fstat(descriptor, &status) == 0 else { throw currentPOSIXError() }
        guard status.st_mode & mode_t(0o777) == mode_t(0o600) else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))
        }
    }

    private static func currentPOSIXError() -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
}
