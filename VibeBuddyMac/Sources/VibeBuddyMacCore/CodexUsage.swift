import Darwin
import Foundation
import VibeBuddyKit

public enum CodexUsageWindowKind: String, Codable, Sendable {
    case primary
    case secondary
}

public struct CodexUsageWindow: Codable, Equatable, Sendable, Identifiable {
    public var kind: CodexUsageWindowKind
    public var usedPercent: Int
    public var windowDurationMinutes: Int?
    public var resetsAt: Date?

    public var id: CodexUsageWindowKind { kind }

    public init(
        kind: CodexUsageWindowKind,
        usedPercent: Int,
        windowDurationMinutes: Int?,
        resetsAt: Date?
    ) {
        self.kind = kind
        self.usedPercent = usedPercent
        self.windowDurationMinutes = windowDurationMinutes
        self.resetsAt = resetsAt
    }
}

/// Account-level Codex usage. It deliberately contains no session identifier or
/// progress state, so quota collection cannot feed the session reducer.
public struct CodexUsageSnapshot: Codable, Equatable, Sendable {
    public var planType: String?
    public var primary: CodexUsageWindow?
    public var secondary: CodexUsageWindow?
    public var lifetimeTokens: Int?
    public var latestDailyTokens: Int?
    public var fetchedAt: Date

    public var windows: [CodexUsageWindow] {
        [primary, secondary].compactMap { $0 }
    }

    public init(
        planType: String?,
        primary: CodexUsageWindow?,
        secondary: CodexUsageWindow?,
        lifetimeTokens: Int?,
        latestDailyTokens: Int?,
        fetchedAt: Date
    ) {
        self.planType = planType
        self.primary = primary
        self.secondary = secondary
        self.lifetimeTokens = lifetimeTokens
        self.latestDailyTokens = latestDailyTokens
        self.fetchedAt = fetchedAt
    }

    func fetched(at date: Date) -> CodexUsageSnapshot {
        var copy = self
        copy.fetchedAt = date
        return copy
    }
}

public enum CodexUsageUnavailableReason: String, Codable, Equatable, Sendable {
    case collectionDisabled
    case cachedData
    case notYetLoaded
    case codexUnavailable
    case notLoggedIn
    case offline
    case rateLimited
    case timedOut
    case incompatibleFormat
    case unknown

    public var displayText: String {
        switch self {
        case .collectionDisabled: return "Collection is turned off"
        case .cachedData: return "Showing cached data while refreshing"
        case .notYetLoaded: return "Waiting for the first refresh"
        case .codexUnavailable: return "Codex CLI is unavailable"
        case .notLoggedIn: return "Codex is not signed in"
        case .offline: return "Offline"
        case .rateLimited: return "Usage service is rate limited"
        case .timedOut: return "Usage refresh timed out"
        case .incompatibleFormat: return "Codex returned an unsupported format"
        case .unknown: return "Usage is temporarily unavailable"
        }
    }
}

public enum CodexUsageError: Error, Equatable, Sendable {
    case codexUnavailable
    case notLoggedIn
    case offline
    case rateLimited
    case timedOut
    case incompatibleFormat
    case unknown

    public var unavailableReason: CodexUsageUnavailableReason {
        switch self {
        case .codexUnavailable: return .codexUnavailable
        case .notLoggedIn: return .notLoggedIn
        case .offline: return .offline
        case .rateLimited: return .rateLimited
        case .timedOut: return .timedOut
        case .incompatibleFormat: return .incompatibleFormat
        case .unknown: return .unknown
        }
    }

    static func classify(message: String) -> CodexUsageError {
        let value = message.lowercased()
        if value.contains("not logged in") || value.contains("not signed in") || value.contains("unauthorized") {
            return .notLoggedIn
        }
        if value.contains("rate limit") || value.contains("too many requests") || value.contains("429") {
            return .rateLimited
        }
        if value.contains("offline") || value.contains("network") || value.contains("not connected") {
            return .offline
        }
        return .unknown
    }
}

public struct CodexUsageState: Equatable, Sendable {
    public var collectionEnabled: Bool
    public var snapshot: CodexUsageSnapshot?
    public var isStale: Bool
    public var unavailableReason: CodexUsageUnavailableReason?
    public var lastAttemptAt: Date?
    public var nextRefreshAt: Date?

    public static let disabled = CodexUsageState(
        collectionEnabled: false,
        snapshot: nil,
        isStale: false,
        unavailableReason: .collectionDisabled,
        lastAttemptAt: nil,
        nextRefreshAt: nil
    )

    public static func available(
        _ snapshot: CodexUsageSnapshot,
        nextRefreshAt: Date?
    ) -> CodexUsageState {
        CodexUsageState(
            collectionEnabled: true,
            snapshot: snapshot,
            isStale: false,
            unavailableReason: nil,
            lastAttemptAt: snapshot.fetchedAt,
            nextRefreshAt: nextRefreshAt
        )
    }

    public static func stale(
        _ snapshot: CodexUsageSnapshot,
        reason: CodexUsageUnavailableReason,
        lastAttemptAt: Date?,
        nextRefreshAt: Date?
    ) -> CodexUsageState {
        CodexUsageState(
            collectionEnabled: true,
            snapshot: snapshot,
            isStale: true,
            unavailableReason: reason,
            lastAttemptAt: lastAttemptAt,
            nextRefreshAt: nextRefreshAt
        )
    }

    public static func unavailable(
        _ reason: CodexUsageUnavailableReason,
        lastAttemptAt: Date?,
        nextRefreshAt: Date?
    ) -> CodexUsageState {
        CodexUsageState(
            collectionEnabled: true,
            snapshot: nil,
            isStale: false,
            unavailableReason: reason,
            lastAttemptAt: lastAttemptAt,
            nextRefreshAt: nextRefreshAt
        )
    }
}

public protocol CodexUsageProviding: Sendable {
    func fetch() async throws -> CodexUsageSnapshot
}

public protocol CodexUsageCaching: Sendable {
    func load() async -> CodexUsageSnapshot?
    func save(_ snapshot: CodexUsageSnapshot) async throws
}

public actor CodexUsageFileCache: CodexUsageCaching {
    private let fileURL: URL
    private let fileManager: FileManager

    public init(fileURL: URL = CodexUsageFileCache.defaultFileURL(), fileManager: FileManager = .default) {
        self.fileURL = fileURL
        self.fileManager = fileManager
    }

    public func load() -> CodexUsageSnapshot? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(CodexUsageSnapshot.self, from: data)
    }

    public func save(_ snapshot: CodexUsageSnapshot) throws {
        let directory = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(snapshot)
        try Self.writeOwnerOnly(data, to: fileURL)
        let attributes = try fileManager.attributesOfItem(atPath: fileURL.path)
        guard (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600 else {
            throw CocoaError(.fileWriteNoPermission)
        }
    }

    public nonisolated static func defaultFileURL(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent("Library/Application Support/VibeBuddy/codex-usage.json")
    }

    /// Build a 0600 temporary file and atomically rename it into place. The
    /// cached account data is therefore never visible with a permissive mode,
    /// even during its first creation.
    private nonisolated static func writeOwnerOnly(_ data: Data, to destination: URL) throws {
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".codex-usage-\(UUID().uuidString).tmp")
        var descriptor = Darwin.open(
            temporary.path,
            O_WRONLY | O_CREAT | O_EXCL,
            mode_t(S_IRUSR | S_IWUSR)
        )
        guard descriptor >= 0 else { throw posixError() }
        var shouldRemoveTemporary = true
        defer {
            if descriptor >= 0 { _ = Darwin.close(descriptor) }
            if shouldRemoveTemporary { _ = Darwin.unlink(temporary.path) }
        }

        try data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            var written = 0
            while written < bytes.count {
                let count = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: written),
                    bytes.count - written
                )
                guard count > 0 else { throw posixError() }
                written += count
            }
        }
        guard Darwin.fchmod(descriptor, mode_t(S_IRUSR | S_IWUSR)) == 0 else {
            throw posixError()
        }
        guard Darwin.fsync(descriptor) == 0 else { throw posixError() }
        guard Darwin.close(descriptor) == 0 else { throw posixError() }
        descriptor = -1
        guard Darwin.rename(temporary.path, destination.path) == 0 else {
            throw posixError()
        }
        shouldRemoveTemporary = false
    }

    private nonisolated static func posixError() -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
}

/// Refresh/cache policy for account usage. This actor has no reference to
/// SessionStore or SessionReducer; failures only change `CodexUsageState`.
public actor CodexUsageCollector {
    private let provider: any CodexUsageProviding
    private let cache: any CodexUsageCaching
    private let refreshInterval: TimeInterval
    private let baseBackoff: TimeInterval
    private let maxBackoff: TimeInterval

    private var isEnabled: Bool
    private var generation: UInt64 = 0
    private var didBootstrap = false
    private var failureCount = 0
    private var state: CodexUsageState

    public init(
        provider: any CodexUsageProviding,
        cache: any CodexUsageCaching,
        refreshInterval: TimeInterval = 15 * 60,
        baseBackoff: TimeInterval = 60,
        maxBackoff: TimeInterval = 15 * 60,
        enabled: Bool
    ) {
        self.provider = provider
        self.cache = cache
        self.refreshInterval = refreshInterval
        self.baseBackoff = baseBackoff
        self.maxBackoff = maxBackoff
        isEnabled = enabled
        state = enabled ? .unavailable(.notYetLoaded, lastAttemptAt: nil, nextRefreshAt: nil) : .disabled
    }

    public func bootstrap(now: Date = Date()) async -> CodexUsageState {
        guard isEnabled else { return .disabled }
        guard !didBootstrap else { return state }
        let currentGeneration = generation
        didBootstrap = true
        let cached = await cache.load()
        guard isEnabled, generation == currentGeneration else { return state }
        if let snapshot = cached {
            state = .stale(snapshot, reason: .cachedData, lastAttemptAt: nil, nextRefreshAt: now)
        } else {
            state = .unavailable(.notYetLoaded, lastAttemptAt: nil, nextRefreshAt: now)
        }
        return state
    }

    public func refresh(now: Date = Date(), ignoringBackoff: Bool = false) async -> CodexUsageState {
        guard isEnabled else { return .disabled }
        if !didBootstrap { _ = await bootstrap(now: now) }
        guard isEnabled else { return state }
        if !ignoringBackoff, let next = state.nextRefreshAt, next > now {
            return state
        }
        let currentGeneration = generation

        do {
            let snapshot = try await provider.fetch().fetched(at: now)
            guard isEnabled, generation == currentGeneration else { return state }
            failureCount = 0
            state = .available(snapshot, nextRefreshAt: now.addingTimeInterval(refreshInterval))
            do {
                try await cache.save(snapshot)
                guard isEnabled, generation == currentGeneration else { return state }
            } catch {
                // A cache write failure must not discard a fresh, trustworthy read.
            }
        } catch {
            guard isEnabled, generation == currentGeneration else { return state }
            failureCount += 1
            let reason = (error as? CodexUsageError)?.unavailableReason ?? .unknown
            let exponent = min(failureCount - 1, 20)
            let delay = min(baseBackoff * pow(2, Double(exponent)), maxBackoff)
            let retryAt = now.addingTimeInterval(delay)
            if let lastKnownGood = state.snapshot {
                state = .stale(lastKnownGood, reason: reason, lastAttemptAt: now, nextRefreshAt: retryAt)
            } else {
                state = .unavailable(reason, lastAttemptAt: now, nextRefreshAt: retryAt)
            }
        }
        return state
    }

    public func setEnabled(_ enabled: Bool, now: Date = Date()) async -> CodexUsageState {
        generation &+= 1
        isEnabled = enabled
        failureCount = 0
        didBootstrap = false
        guard enabled else {
            state = .disabled
            return state
        }
        state = .unavailable(.notYetLoaded, lastAttemptAt: nil, nextRefreshAt: now)
        return await bootstrap(now: now)
    }
}

/// One alert per quota-window identity. The first fresh snapshot is a baseline,
/// not a crossing; stale data never alerts. Alerted identities are exportable so
/// a restart cannot re-notify the same reset window.
public struct CodexUsageAlertMonitor: Sendable {
    public private(set) var alertedWindowKeys: Set<String>
    private var observedWindowKeys: Set<String> = []
    private var didObserveFreshSnapshot = false

    public init(alertedWindowKeys: Set<String> = []) {
        self.alertedWindowKeys = alertedWindowKeys
    }

    public mutating func newlyCrossed(
        in state: CodexUsageState,
        thresholdPercent: Int,
        notificationsSuppressed: Bool = false
    ) -> [CodexUsageWindow] {
        guard thresholdPercent > 0 else { return [] }
        guard state.collectionEnabled, !state.isStale, let snapshot = state.snapshot else { return [] }

        let currentKeys = Dictionary(uniqueKeysWithValues: snapshot.windows.map { ($0.kind, Self.key(for: $0)) })
        for (kind, currentKey) in currentKeys {
            let prefix = kind.rawValue + "|"
            alertedWindowKeys = alertedWindowKeys.filter {
                !$0.hasPrefix(prefix) || $0 == currentKey
            }
            observedWindowKeys = observedWindowKeys.filter {
                !$0.hasPrefix(prefix) || $0 == currentKey
            }
        }

        if !didObserveFreshSnapshot {
            didObserveFreshSnapshot = true
            for window in snapshot.windows {
                let key = Self.key(for: window)
                observedWindowKeys.insert(key)
                if window.usedPercent >= thresholdPercent {
                    alertedWindowKeys.insert(key)
                }
            }
            return []
        }

        var alerts: [CodexUsageWindow] = []
        for window in snapshot.windows {
            let key = Self.key(for: window)
            guard observedWindowKeys.contains(key) else {
                observedWindowKeys.insert(key)
                if window.usedPercent >= thresholdPercent {
                    alertedWindowKeys.insert(key)
                }
                continue
            }
            guard window.usedPercent >= thresholdPercent,
                  !alertedWindowKeys.contains(key) else { continue }
            alertedWindowKeys.insert(key)
            if !notificationsSuppressed { alerts.append(window) }
        }
        return alerts
    }

    private static func key(for window: CodexUsageWindow) -> String {
        let reset = window.resetsAt
            .map { String(Int64($0.timeIntervalSince1970.rounded())) }
            ?? "none"
        let duration = window.windowDurationMinutes.map(String.init) ?? "none"
        return "\(window.kind.rawValue)|\(reset)|\(duration)"
    }
}

/// Shared interpretation of the manual and scheduled quiet settings. All
/// non-approval notification paths should consult this policy.
public enum NotificationQuietMode {
    public static func isEffective(
        defaults: UserDefaults = .standard,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> Bool {
        if defaults.bool(forKey: "quietMode") { return true }
        guard let data = defaults.data(forKey: "quietHours"),
              let quietHours = try? JSONDecoder().decode(QuietHours.self, from: data) else {
            return false
        }
        return quietHours.isQuiet(at: now, calendar: calendar)
    }
}
