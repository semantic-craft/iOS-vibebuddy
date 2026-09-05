import Foundation

public enum NotificationDeliveryLogLocation {
    public static func defaultURL(
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        home.appendingPathComponent("Library/Application Support/vibebuddy/notification-delivery.json")
    }
}

/// Bounded send log (250 entries / 7 days). Independent of `LifecycleJournal`.
struct NotificationDeliveryLog {
    static let maxEntries = 250
    static let retention: TimeInterval = 7 * 24 * 60 * 60

    private struct Envelope: Codable {
        let schemaVersion: Int
        let entries: [NotificationDeliveryRecord]
    }

    let url: URL
    private let capacity: Int
    private let retention: TimeInterval
    private(set) var entries: [NotificationDeliveryRecord]

    init(
        url: URL,
        capacity: Int = NotificationDeliveryLog.maxEntries,
        retention: TimeInterval = NotificationDeliveryLog.retention,
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
            envelope.entries, capacity: self.capacity, retention: self.retention, now: now)
    }

    mutating func append(_ record: NotificationDeliveryRecord, now: Date) {
        entries.append(record)
        entries = Self.pruned(entries, capacity: capacity, retention: retention, now: now)
        persistBestEffort()
    }

    func recent(limit: Int) -> [NotificationDeliveryRecord] {
        Array(entries.suffix(max(0, limit)).reversed())
    }

    private static func pruned(
        _ entries: [NotificationDeliveryRecord],
        capacity: Int,
        retention: TimeInterval,
        now: Date
    ) -> [NotificationDeliveryRecord] {
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
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(Envelope(schemaVersion: 1, entries: entries))
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            // Fail open: delivery recording must never break session monitoring.
        }
    }
}

/// Shared sink for local + APNs send records. Health diagnostics are latched
/// here; this type never posts a notification of its own.
public actor NotificationDeliveryRecorder: NotificationDeliveryRecording {
    private var log: NotificationDeliveryLog
    private var tracker: NotificationDeliveryHealthTracker
    private var authorization: NotificationAuthorization
    private var apnsConfigured: Bool

    public init(
        url: URL,
        failureDebounce: TimeInterval = 5 * 60,
        now: Date = Date(),
        authorization: NotificationAuthorization = .notDetermined,
        apnsConfigured: Bool = false
    ) {
        self.log = NotificationDeliveryLog(url: url, now: now)
        self.tracker = NotificationDeliveryHealthTracker(debounce: failureDebounce)
        self.authorization = authorization
        self.apnsConfigured = apnsConfigured
        // Replay the whole retained log, not just the last record: a `skipped`
        // (or `attempted`) neither latches a failure nor clears one, so seeding
        // from one of those would drop a failure that is still standing — and
        // skips are common enough that the last record often is one. Oldest
        // first, each at its own timestamp, so the latch ends up where the
        // history actually put it.
        for record in log.entries {
            _ = tracker.apply(record, now: record.timestamp)
        }
    }

    public func record(_ record: NotificationDeliveryRecord) {
        log.append(record, now: record.timestamp)
        _ = tracker.apply(record, now: record.timestamp)
    }

    public func updateAuthorization(_ authorization: NotificationAuthorization) {
        self.authorization = authorization
    }

    public func updateAPNsConfigured(_ configured: Bool) {
        apnsConfigured = configured
    }

    public func health() -> NotificationDeliveryHealth {
        NotificationDeliveryHealth(
            authorization: authorization,
            apnsConfigured: apnsConfigured,
            lastAttempt: tracker.lastAttempt,
            latchedFailure: tracker.latchedFailure
        )
    }

    public func recent(limit: Int = 20) -> [NotificationDeliveryRecord] {
        log.recent(limit: limit)
    }
}
