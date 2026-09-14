import Foundation
import VibeBuddyKit

/// PLAN §2.3: the widget only learns anything while the app is open, so the
/// Kit's 15-minute stale rule would mark it stale most of the day. It prints
/// the age as a fact and fades only when the phone saw the Mac drop or the
/// reading is over an hour old.
enum QuotaFreshnessRule {
    static let fadeAfter: TimeInterval = 60 * 60

    /// The overview reports its oldest reading; single-provider widgets
    /// pass only their own quota. Missing timestamps use the save time.
    static func anchor(_ snapshot: PhoneQuotaSnapshot, quotas: [ProviderQuota]) -> Date {
        quotas.map { $0.observedAt ?? snapshot.savedAt }.min() ?? snapshot.savedAt
    }

    static func faded(_ snapshot: PhoneQuotaSnapshot, quotas: [ProviderQuota], now: Date) -> Bool {
        !snapshot.relayLive || now.timeIntervalSince(anchor(snapshot, quotas: quotas)) >= fadeAfter
    }

    /// Each overview row keeps its own age; one recent provider cannot
    /// make an older provider appear live (or vice versa).
    static func fadedProviders(_ snapshot: PhoneQuotaSnapshot, now: Date) -> Set<AccountUsageProvider> {
        Set(snapshot.quotas.filter { faded(snapshot, quotas: [$0], now: now) }.map(\.provider))
    }

    /// Schedule every provider's fade, including the selected provider of a
    /// small widget when another provider has a newer reading.
    static func fadeDates(_ snapshot: PhoneQuotaSnapshot) -> [Date] {
        let anchors = snapshot.quotas.map { $0.observedAt ?? snapshot.savedAt }
        return (anchors.isEmpty ? [snapshot.savedAt] : anchors).map { $0.addingTimeInterval(fadeAfter) }
    }

    /// `18m ago`, or nil while the reading is live and recent.
    static func age(_ snapshot: PhoneQuotaSnapshot, quotas: [ProviderQuota], now: Date) -> String? {
        let seconds = max(0, now.timeIntervalSince(anchor(snapshot, quotas: quotas)))
        if snapshot.relayLive, seconds < ProviderQuota.staleAfter { return nil }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return String(localized: "\(minutes)m ago") }
        if minutes < 1440 { return String(localized: "\(minutes / 60)h ago") }
        return String(localized: "\(minutes / 1440)d ago")
    }
}

