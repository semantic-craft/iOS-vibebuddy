import Foundation

/// A provider whose account allowance vibebuddy can read locally.
///
/// Raw values are stable wire strings and match the on-disk usage cache the Mac
/// already writes.
public enum AccountUsageProvider: String, Codable, CaseIterable, Sendable, Identifiable {
    case codex
    case claude
    case grok
    case cursor

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .codex: return "Codex"
        case .claude: return "Claude"
        case .grok: return "Grok"
        case .cursor: return "Cursor"
        }
    }
}

/// Quality of one observed value, recomputed from the current clock.
public enum QuotaFreshness: String, Codable, Sendable {
    case live
    case stale
    case unavailable
}

/// One provider's allowance, normalized once and expressed as **percent
/// remaining** everywhere downstream.
///
/// This is the single quota vocabulary: the Mac composes it into the runtime
/// snapshot, the iPhone renders and relays it, and the Watch shows it. Provider
/// adapters do the consumed-to-remaining conversion exactly once, on the Mac,
/// where the provider's own convention is still known.
///
/// A missing value stays missing. Absence renders as unavailable, never as
/// "0% left" — those mean opposite things to someone deciding whether to keep
/// working. Each window is independently usable.
public struct ProviderQuota: Codable, Equatable, Sendable, Identifiable {
    /// A weekly value observed longer ago than this reads as stale.
    public static let staleAfter: TimeInterval = 15 * 60

    public var provider: AccountUsageProvider
    public var weeklyRemainingPercent: Int?
    public var weeklyResetsAt: Date?
    public var weeklyWindowDurationMinutes: Int?
    public var shortWindowRemainingPercent: Int?
    public var shortWindowResetsAt: Date?
    public var shortWindowDurationMinutes: Int?
    /// Windows whose duration cannot truthfully be called weekly or short.
    public var otherWindows: [QuotaWindow]?
    /// When the Mac last read a usable value from this provider's local source.
    public var observedAt: Date?
    /// Why the source produced nothing, when it produced nothing.
    public var unavailableReason: String?
    public var isCached: Bool?

    public var id: AccountUsageProvider { provider }

    public init(
        provider: AccountUsageProvider,
        weeklyRemainingPercent: Int? = nil,
        weeklyResetsAt: Date? = nil,
        weeklyWindowDurationMinutes: Int? = nil,
        shortWindowRemainingPercent: Int? = nil,
        shortWindowResetsAt: Date? = nil,
        shortWindowDurationMinutes: Int? = nil,
        otherWindows: [QuotaWindow]? = nil,
        observedAt: Date? = nil,
        unavailableReason: String? = nil,
        isCached: Bool? = nil
    ) {
        self.provider = provider
        self.weeklyRemainingPercent = Self.validated(weeklyRemainingPercent)
        self.weeklyResetsAt = weeklyResetsAt
        self.weeklyWindowDurationMinutes = weeklyWindowDurationMinutes
        self.shortWindowRemainingPercent = Self.validated(shortWindowRemainingPercent)
        self.shortWindowResetsAt = shortWindowResetsAt
        self.shortWindowDurationMinutes = shortWindowDurationMinutes
        self.otherWindows = otherWindows
        self.observedAt = observedAt
        self.unavailableReason = unavailableReason
        self.isCached = isCached
    }

    /// A provider whose local source produced no usable value.
    public static func unavailable(_ provider: AccountUsageProvider, reason: String) -> ProviderQuota {
        ProviderQuota(provider: provider, unavailableReason: reason)
    }

    /// Recomputed against the caller's clock, so a state restored from disk
    /// cannot claim a stale number is live.
    public func freshness(now: Date) -> QuotaFreshness {
        guard weeklyRemainingPercent != nil || shortWindowRemainingPercent != nil ||
                (otherWindows ?? []).contains(where: { $0.remainingPercent != nil }),
              let observedAt else { return .unavailable }
        return isCached == true || now.timeIntervalSince(observedAt) >= Self.staleAfter ? .stale : .live
    }

    public func age(now: Date) -> TimeInterval? {
        observedAt.map { max(0, now.timeIntervalSince($0)) }
    }

    /// Convert a provider's consumed percentage to remaining. Out-of-range input
    /// is a malformed reading, not a clamped one: a source claiming 140% used
    /// has not told us anything trustworthy about what is left.
    public static func remaining(fromUsedPercent used: Int?) -> Int? {
        guard let used, (0...100).contains(used) else { return nil }
        return 100 - used
    }

    private static func validated(_ percent: Int?) -> Int? {
        guard let percent, (0...100).contains(percent) else { return nil }
        return percent
    }
}


public enum QuotaWindowKind: String, Codable, CaseIterable, Sendable {
    case weekly
    case short
}

public enum QuotaWindowStatus: String, Sendable {
    case live, stale, unavailable, awaitingReset
}

/// A single source reading. The timestamp never changes during relay or rendering.
public struct QuotaWindow: Codable, Equatable, Sendable {
    public var remainingPercent: Int?
    public var durationMinutes: Int?
    public var resetsAt: Date?
    public var observedAt: Date?
    public var isCached: Bool?

    public init(remainingPercent: Int?, durationMinutes: Int?, resetsAt: Date?, observedAt: Date?, isCached: Bool? = nil) {
        self.remainingPercent = remainingPercent.flatMap { (0...100).contains($0) ? $0 : nil }
        self.durationMinutes = durationMinutes.flatMap { $0 > 0 ? $0 : nil }
        self.resetsAt = resetsAt
        self.observedAt = observedAt
        self.isCached = isCached
    }

    public func status(now: Date) -> QuotaWindowStatus {
        guard let remainingPercent, (0...100).contains(remainingPercent), let observedAt else { return .unavailable }
        if let resetsAt, resetsAt <= now { return .awaitingReset }
        return isCached == true || now.timeIntervalSince(observedAt) >= ProviderQuota.staleAfter ? .stale : .live
    }

    /// Old readings stay available for detail, but never masquerade as a current balance after reset.
    public func currentRemainingPercent(now: Date) -> Int? {
        switch status(now: now) {
        case .live, .stale: return remainingPercent
        case .unavailable, .awaitingReset: return nil
        }
    }
}

public extension ProviderQuota {
    func window(_ kind: QuotaWindowKind) -> QuotaWindow {
        switch kind {
        case .weekly:
            return QuotaWindow(remainingPercent: weeklyRemainingPercent,
                               durationMinutes: weeklyWindowDurationMinutes,
                               resetsAt: weeklyResetsAt, observedAt: observedAt, isCached: isCached)
        case .short:
            return QuotaWindow(remainingPercent: shortWindowRemainingPercent,
                               durationMinutes: shortWindowDurationMinutes,
                               resetsAt: shortWindowResetsAt, observedAt: observedAt, isCached: isCached)
        }
    }
}
