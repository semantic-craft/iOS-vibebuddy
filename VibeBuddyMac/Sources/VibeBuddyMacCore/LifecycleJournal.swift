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

    public init(
        id: UUID = UUID(),
        sessionID: String,
        agent: AgentKind,
        event: String,
        source: ObservationSource,
        timestamp: Date,
        status: SessionStatus?,
        waitKind: WaitKind?
    ) {
        self.id = id
        self.sessionID = sessionID
        self.agent = agent
        self.event = event
        self.source = source
        self.timestamp = timestamp
        self.status = status
        self.waitKind = waitKind
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
    }

    let url: URL
    private let capacity: Int
    private let retention: TimeInterval
    private(set) var entries: [LifecycleJournalEntry]

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
        entries = Self.pruned(
            envelope.entries,
            capacity: self.capacity,
            retention: self.retention,
            now: now
        )
    }

    mutating func append(_ entry: LifecycleJournalEntry, now: Date) {
        entries.append(entry)
        entries = Self.pruned(entries, capacity: capacity, retention: retention, now: now)
        persistBestEffort()
    }

    func recent(limit: Int) -> [LifecycleJournalEntry] {
        Array(entries.suffix(max(0, limit)).reversed())
    }

    /// Recover only a recent final active/wait state per session. A later done,
    /// session-end, or reconciliation record tombstones earlier active state.
    func restorableSessions(now: Date, meaningfulFor: TimeInterval) -> [AgentSession] {
        var latest: [String: LifecycleJournalEntry] = [:]
        for entry in entries { latest[entry.sessionID] = entry }
        return latest.values.compactMap { entry in
            guard let status = entry.status,
                  status == .working || status == .needsResponse,
                  now.timeIntervalSince(entry.timestamp) <= max(0, meaningfulFor)
            else { return nil }
            return AgentSession(
                id: entry.sessionID,
                agent: entry.agent,
                project: "—",
                status: status,
                waitKind: entry.waitKind,
                observations: [ObservationEvidence(
                    source: .recovery,
                    lastObservedAt: entry.timestamp,
                    health: .healthy
                )],
                statusSince: entry.timestamp,
                updatedAt: entry.timestamp
            )
        }
    }

    /// Returns false when old on-disk data could not be removed. Failed clears
    /// keep the in-memory entries so the UI accurately shows that data remains
    /// and can offer the clear action again after permissions are repaired.
    mutating func clear() -> Bool {
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

    private func persistBestEffort() {
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
            let data = try encoder.encode(Envelope(schemaVersion: 1, entries: entries))
            try publishSecurely(data, in: directory)
        } catch {
            // Fail open: persistence must never affect hook/rollout processing.
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
