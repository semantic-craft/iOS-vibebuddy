import Darwin
import Foundation
import VibeBuddyKit

public enum AccountUsageWindowKind: String, Codable, Sendable {
    case primary
    case secondary
}

public struct AccountUsageWindow: Codable, Equatable, Sendable, Identifiable {
    public var kind: AccountUsageWindowKind
    public var usedPercent: Int
    public var windowDurationMinutes: Int?
    public var resetsAt: Date?
    public var label: String?

    public var id: AccountUsageWindowKind { kind }

    public init(
        kind: AccountUsageWindowKind,
        usedPercent: Int,
        windowDurationMinutes: Int?,
        resetsAt: Date?,
        label: String? = nil
    ) {
        self.kind = kind
        self.usedPercent = usedPercent
        self.windowDurationMinutes = windowDurationMinutes
        self.resetsAt = resetsAt
        self.label = label
    }
}

/// Account-level provider usage. It deliberately contains no session identifier
/// or progress state, so quota collection cannot feed the session reducer.
public struct AccountUsageSnapshot: Codable, Equatable, Sendable {
    public var provider: AccountUsageProvider
    public var planType: String?
    public var primary: AccountUsageWindow?
    public var secondary: AccountUsageWindow?
    public var lifetimeTokens: Int?
    public var latestDailyTokens: Int?
    public var fetchedAt: Date

    public var windows: [AccountUsageWindow] {
        [primary, secondary].compactMap { $0 }
    }

    public init(
        provider: AccountUsageProvider,
        planType: String?,
        primary: AccountUsageWindow?,
        secondary: AccountUsageWindow?,
        lifetimeTokens: Int?,
        latestDailyTokens: Int?,
        fetchedAt: Date
    ) {
        self.provider = provider
        self.planType = planType
        self.primary = primary
        self.secondary = secondary
        self.lifetimeTokens = lifetimeTokens
        self.latestDailyTokens = latestDailyTokens
        self.fetchedAt = fetchedAt
    }

}

public enum AccountUsageUnavailableReason: String, Codable, Equatable, Sendable {
    case collectionDisabled
    case cachedData
    case notYetLoaded
    case providerUnavailable
    case notLoggedIn
    case offline
    case rateLimited
    case timedOut
    case incompatibleFormat
    case unknown

    public func displayText(provider: AccountUsageProvider) -> String {
        switch self {
        case .collectionDisabled: return "Collection is turned off"
        case .cachedData: return "Showing cached data while refreshing"
        case .notYetLoaded: return "Waiting for the first refresh"
        case .providerUnavailable: return "\(provider.displayName) CLI is unavailable"
        case .notLoggedIn: return "\(provider.displayName) is not signed in"
        case .offline: return "Offline"
        case .rateLimited: return "Usage service is rate limited"
        case .timedOut: return "Usage refresh timed out"
        case .incompatibleFormat: return "\(provider.displayName) returned an unsupported format"
        case .unknown: return "Usage is temporarily unavailable"
        }
    }
}

public enum AccountUsageError: Error, Equatable, Sendable {
    case providerUnavailable
    case notLoggedIn
    case offline
    case rateLimited
    case timedOut
    case incompatibleFormat
    case unknown

    public var unavailableReason: AccountUsageUnavailableReason {
        switch self {
        case .providerUnavailable: return .providerUnavailable
        case .notLoggedIn: return .notLoggedIn
        case .offline: return .offline
        case .rateLimited: return .rateLimited
        case .timedOut: return .timedOut
        case .incompatibleFormat: return .incompatibleFormat
        case .unknown: return .unknown
        }
    }

    static func classify(message: String) -> AccountUsageError {
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

public struct AccountUsageState: Equatable, Sendable {
    public var collectionEnabled: Bool
    public var snapshot: AccountUsageSnapshot?
    public var isStale: Bool
    public var unavailableReason: AccountUsageUnavailableReason?
    public var lastAttemptAt: Date?
    public var nextRefreshAt: Date?

    public static let disabled = AccountUsageState(
        collectionEnabled: false,
        snapshot: nil,
        isStale: false,
        unavailableReason: .collectionDisabled,
        lastAttemptAt: nil,
        nextRefreshAt: nil
    )

    public static func available(
        _ snapshot: AccountUsageSnapshot,
        nextRefreshAt: Date?
    ) -> AccountUsageState {
        AccountUsageState(
            collectionEnabled: true,
            snapshot: snapshot,
            isStale: false,
            unavailableReason: nil,
            lastAttemptAt: snapshot.fetchedAt,
            nextRefreshAt: nextRefreshAt
        )
    }

    public static func stale(
        _ snapshot: AccountUsageSnapshot,
        reason: AccountUsageUnavailableReason,
        lastAttemptAt: Date?,
        nextRefreshAt: Date?
    ) -> AccountUsageState {
        AccountUsageState(
            collectionEnabled: true,
            snapshot: snapshot,
            isStale: true,
            unavailableReason: reason,
            lastAttemptAt: lastAttemptAt,
            nextRefreshAt: nextRefreshAt
        )
    }

    public static func unavailable(
        _ reason: AccountUsageUnavailableReason,
        lastAttemptAt: Date?,
        nextRefreshAt: Date?
    ) -> AccountUsageState {
        AccountUsageState(
            collectionEnabled: true,
            snapshot: nil,
            isStale: false,
            unavailableReason: reason,
            lastAttemptAt: lastAttemptAt,
            nextRefreshAt: nextRefreshAt
        )
    }
}

public protocol AccountUsageProviding: Sendable {
    func fetch() async throws -> AccountUsageSnapshot
}

/// A cache write can prepare data asynchronously, but its final mutation must
/// pass through this permit. The generation check and final commit share one
/// lock with enable/disable changes, making the result linearizable.
public final class AccountUsageCacheCommitPermit: @unchecked Sendable {
    private let gate: AccountUsageCacheCommitGate
    private let generation: UInt64

    fileprivate init(gate: AccountUsageCacheCommitGate, generation: UInt64) {
        self.gate = gate
        self.generation = generation
    }

    @discardableResult
    public func commit(_ operation: () throws -> Void) rethrows -> Bool {
        try gate.commit(generation: generation, operation)
    }
}

public protocol AccountUsageCaching: Sendable {
    func load() async -> AccountUsageSnapshot?
    func save(
        _ snapshot: AccountUsageSnapshot,
        permit: AccountUsageCacheCommitPermit
    ) async throws
}

private final class AccountUsageCacheCommitGate: @unchecked Sendable {
    private let lock = NSLock()
    private var generation: UInt64
    private var enabled: Bool

    init(generation: UInt64, enabled: Bool) {
        self.generation = generation
        self.enabled = enabled
    }

    func update(generation: UInt64, enabled: Bool) {
        lock.withLock {
            self.generation = generation
            self.enabled = enabled
        }
    }

    func permit(generation: UInt64) -> AccountUsageCacheCommitPermit {
        AccountUsageCacheCommitPermit(gate: self, generation: generation)
    }

    func commit(
        generation: UInt64,
        _ operation: () throws -> Void
    ) rethrows -> Bool {
        try lock.withLock {
            guard enabled, self.generation == generation else { return false }
            try operation()
            return true
        }
    }
}

public actor AccountUsageFileCache: AccountUsageCaching {
    private let fileURL: URL
    private let fileManager: FileManager

    public init(provider: AccountUsageProvider, fileManager: FileManager = .default) {
        self.fileURL = Self.defaultFileURL(provider: provider)
        self.fileManager = fileManager
    }

    public init(fileURL: URL, fileManager: FileManager = .default) {
        self.fileURL = fileURL
        self.fileManager = fileManager
    }

    public func load() -> AccountUsageSnapshot? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(AccountUsageSnapshot.self, from: data)
    }

    public func save(
        _ snapshot: AccountUsageSnapshot,
        permit: AccountUsageCacheCommitPermit
    ) throws {
        let directory = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(snapshot)
        let temporary = try Self.writeOwnerOnlyTemporary(data, beside: fileURL)
        var shouldRemoveTemporary = true
        defer {
            if shouldRemoveTemporary { _ = Darwin.unlink(temporary.path) }
        }
        let committed = try permit.commit {
            guard Darwin.rename(temporary.path, fileURL.path) == 0 else {
                throw Self.posixError()
            }
        }
        guard committed else { return }
        shouldRemoveTemporary = false
        let attributes = try fileManager.attributesOfItem(atPath: fileURL.path)
        guard (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600 else {
            throw CocoaError(.fileWriteNoPermission)
        }
    }

    public nonisolated static func defaultFileURL(
        provider: AccountUsageProvider,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        home.appendingPathComponent("Library/Application Support/VibeBuddy/\(provider.rawValue)-usage.json")
    }

    /// Build a 0600 temporary file and atomically rename it into place. The
    /// cached account data is therefore never visible with a permissive mode,
    /// even during its first creation.
    private nonisolated static func writeOwnerOnlyTemporary(
        _ data: Data,
        beside destination: URL
    ) throws -> URL {
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".account-usage-\(UUID().uuidString).tmp")
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
        shouldRemoveTemporary = false
        return temporary
    }

    private nonisolated static func posixError() -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
}

/// Refresh/cache policy for account usage. This actor has no reference to
/// SessionStore or SessionReducer; failures only change `AccountUsageState`.
public actor AccountUsageCollector {
    private let provider: any AccountUsageProviding
    private let cache: any AccountUsageCaching
    private let refreshInterval: TimeInterval
    private let baseBackoff: TimeInterval
    private let maxBackoff: TimeInterval
    private let cacheCommitGate: AccountUsageCacheCommitGate

    private var isEnabled: Bool
    private var generation: UInt64 = 0
    private var didBootstrap = false
    private var failureCount = 0
    private var state: AccountUsageState

    public init(
        provider: any AccountUsageProviding,
        cache: any AccountUsageCaching,
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
        cacheCommitGate = AccountUsageCacheCommitGate(generation: 0, enabled: enabled)
        isEnabled = enabled
        state = enabled ? .unavailable(.notYetLoaded, lastAttemptAt: nil, nextRefreshAt: nil) : .disabled
    }

    public func bootstrap(now: Date = Date()) async -> AccountUsageState {
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

    public func refresh(now: Date = Date(), ignoringBackoff: Bool = false) async -> AccountUsageState {
        guard isEnabled else { return .disabled }
        if !didBootstrap { _ = await bootstrap(now: now) }
        guard isEnabled else { return state }
        if !ignoringBackoff, let next = state.nextRefreshAt, next > now {
            return state
        }
        let currentGeneration = generation
        let cachePermit = cacheCommitGate.permit(generation: currentGeneration)

        do {
            let snapshot = try await provider.fetch()
            guard isEnabled, generation == currentGeneration else { return state }
            failureCount = 0
            state = .available(snapshot, nextRefreshAt: now.addingTimeInterval(refreshInterval))
            do {
                try await cache.save(snapshot, permit: cachePermit)
                guard isEnabled, generation == currentGeneration else { return state }
            } catch {
                // A cache write failure must not discard a fresh, trustworthy read.
            }
        } catch {
            guard isEnabled, generation == currentGeneration else { return state }
            failureCount += 1
            let reason = (error as? AccountUsageError)?.unavailableReason ?? .unknown
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

    /// A snapshot that arrived on its own (the status line, the app-server
    /// stream). It is as good as a fetch: it becomes the current state, is
    /// cached, and pushes the next scheduled fetch out by `holdFor`, so the
    /// spawning provider stays idle while live samples keep coming.
    public func acceptLive(_ snapshot: AccountUsageSnapshot, holdFor: TimeInterval,
                           now: Date = Date()) async -> AccountUsageState {
        guard isEnabled else { return .disabled }
        if !didBootstrap { _ = await bootstrap(now: now) }
        guard isEnabled else { return state }
        let currentGeneration = generation
        failureCount = 0
        let live = snapshot
        state = .available(live, nextRefreshAt: now.addingTimeInterval(holdFor))
        do {
            try await cache.save(live, permit: cacheCommitGate.permit(generation: currentGeneration))
        } catch {
            // A cache write failure must not discard a fresh, trustworthy read.
        }
        return state
    }

    public func setEnabled(_ enabled: Bool, now: Date = Date()) async -> AccountUsageState {
        generation &+= 1
        isEnabled = enabled
        cacheCommitGate.update(generation: generation, enabled: enabled)
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
public struct AccountUsageAlertMonitor: Sendable {
    public private(set) var alertedWindowKeys: Set<String>
    private var observedWindowKeys: Set<String> = []
    private var didObserveFreshSnapshot = false

    public init(alertedWindowKeys: Set<String> = []) {
        self.alertedWindowKeys = alertedWindowKeys
    }

    public mutating func newlyCrossed(
        in state: AccountUsageState,
        thresholdPercent: Int,
        notificationsSuppressed: Bool = false
    ) -> [AccountUsageWindow] {
        guard thresholdPercent > 0 else { return [] }
        guard state.collectionEnabled, !state.isStale, let snapshot = state.snapshot else { return [] }

        let currentKeys = Dictionary(uniqueKeysWithValues: snapshot.windows.map {
            ($0.kind, Self.key(provider: snapshot.provider, window: $0))
        })
        for (kind, currentKey) in currentKeys {
            let prefix = snapshot.provider.rawValue + "|" + kind.rawValue + "|"
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
                let key = Self.key(provider: snapshot.provider, window: window)
                observedWindowKeys.insert(key)
                if window.usedPercent >= thresholdPercent {
                    alertedWindowKeys.insert(key)
                }
            }
            return []
        }

        var alerts: [AccountUsageWindow] = []
        for window in snapshot.windows {
            let key = Self.key(provider: snapshot.provider, window: window)
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

    private static func key(provider: AccountUsageProvider, window: AccountUsageWindow) -> String {
        let reset = window.resetsAt
            .map { String(Int64($0.timeIntervalSince1970.rounded())) }
            ?? "none"
        let duration = window.windowDurationMinutes.map(String.init) ?? "none"
        return "\(provider.rawValue)|\(window.kind.rawValue)|\(reset)|\(duration)"
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

extension UserDefaults {
    /// A Bool default that treats an absent key as `fallback` (so first launch
    /// reads as on/off per the caller's choice, not always `false`).
    public func bool(forKey key: String, default fallback: Bool) -> Bool {
        object(forKey: key) == nil ? fallback : bool(forKey: key)
    }
}
