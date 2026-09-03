import Foundation

/// A provider whose account allowance vibebuddy can read locally.
///
/// Raw values are stable wire strings and match the on-disk usage cache the Mac
/// already writes.
public enum AccountUsageProvider: String, Codable, CaseIterable, Sendable, Identifiable {
    case codex
    case claude
    case grok

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .codex: return "Codex"
        case .claude: return "Claude"
        case .grok: return "Grok"
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
/// working. The weekly window is required for a provider to count as available;
/// a five-hour or other short window is optional detail.
public struct ProviderQuota: Codable, Equatable, Sendable, Identifiable {
    /// A weekly value observed longer ago than this reads as stale.
    public static let staleAfter: TimeInterval = 15 * 60

    public var provider: AccountUsageProvider
    public var weeklyRemainingPercent: Int?
    public var weeklyResetsAt: Date?
    public var shortWindowRemainingPercent: Int?
    public var shortWindowResetsAt: Date?
    /// When the Mac last read a usable value from this provider's local source.
    public var observedAt: Date?
    /// Why the source produced nothing, when it produced nothing.
    public var unavailableReason: String?

    public var id: AccountUsageProvider { provider }

    public init(
        provider: AccountUsageProvider,
        weeklyRemainingPercent: Int? = nil,
        weeklyResetsAt: Date? = nil,
        shortWindowRemainingPercent: Int? = nil,
        shortWindowResetsAt: Date? = nil,
        observedAt: Date? = nil,
        unavailableReason: String? = nil
    ) {
        self.provider = provider
        self.weeklyRemainingPercent = Self.clamped(weeklyRemainingPercent)
        self.weeklyResetsAt = weeklyResetsAt
        self.shortWindowRemainingPercent = Self.clamped(shortWindowRemainingPercent)
        self.shortWindowResetsAt = shortWindowResetsAt
        self.observedAt = observedAt
        self.unavailableReason = unavailableReason
    }

    /// A provider whose local source produced no usable value.
    public static func unavailable(_ provider: AccountUsageProvider, reason: String) -> ProviderQuota {
        ProviderQuota(provider: provider, unavailableReason: reason)
    }

    /// Recomputed against the caller's clock, so a state restored from disk
    /// cannot claim a stale number is live.
    public func freshness(now: Date) -> QuotaFreshness {
        guard weeklyRemainingPercent != nil, let observedAt else { return .unavailable }
        return now.timeIntervalSince(observedAt) >= Self.staleAfter ? .stale : .live
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

    private static func clamped(_ percent: Int?) -> Int? {
        percent.map { min(100, max(0, $0)) }
    }
}
