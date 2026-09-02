import SwiftUI
import VibeBuddyKit

/// One of the three canonical buckets, bound to the shared presentation
/// vocabulary so the Watch borrows the Mac and iPhone's colour and symbol
/// instead of inventing a second status language.
enum WatchBucket: CaseIterable {
    case needsResponse
    case working
    case done

    var presentation: TaskPresentationState {
        switch self {
        case .needsResponse: return .requiresInput
        case .working: return .thinking
        case .done: return .completeUnread
        }
    }

    var title: LocalizedStringResource {
        switch self {
        case .needsResponse: return "Needs response"
        case .working: return "Working"
        case .done: return "Done"
        }
    }

    func count(in counts: WatchSessionCounts) -> Int {
        switch self {
        case .needsResponse: return counts.needsResponse
        case .working: return counts.working
        case .done: return counts.done
        }
    }

    var color: Color { Color(taskStatus: presentation.colorToken) }
    var symbolName: String { presentation.symbolName }
}

enum WatchFormat {
    /// "38s", "4m", "3d 8h" — localized, and short enough for a wrist.
    static func duration(_ interval: TimeInterval) -> String {
        let seconds = max(0, interval)
        let allowed: Set<Duration.UnitsFormatStyle.Unit>
        switch seconds {
        case ..<60: allowed = [.seconds]
        case ..<3_600: allowed = [.minutes]
        case ..<86_400: allowed = [.hours, .minutes]
        default: allowed = [.days, .hours]
        }
        return Duration.seconds(seconds)
            .formatted(.units(allowed: allowed, width: .narrow, maximumUnitCount: 2))
    }

    /// A remaining share, localized ("84%"), never hand-assembled from a literal.
    static func percent(_ value: Int) -> String {
        (Double(value) / 100).formatted(.percent)
    }

    /// How old an observation is, or "Just updated" when it is brand new.
    static func updated(_ age: TimeInterval?) -> String {
        guard let age else { return String(localized: "Never updated") }
        if age < 10 { return String(localized: "Just updated") }
        return String(localized: "Updated \(duration(age)) ago")
    }
}

extension QuotaFreshness {
    var symbolName: String? {
        switch self {
        case .live: return nil
        case .stale: return "clock.badge.exclamationmark"
        case .unavailable: return "exclamationmark.triangle"
        }
    }

    var label: LocalizedStringResource? {
        switch self {
        case .live: return nil
        case .stale: return "Stale"
        case .unavailable: return "Unavailable"
        }
    }
}

enum WatchQuotaVoice {
    /// One spoken sentence per provider, so VoiceOver never has to infer a bar.
    static func summary(_ quota: ProviderQuota, freshness: QuotaFreshness) -> String {
        guard let remaining = quota.weeklyRemainingPercent else {
            guard let reason = quota.unavailableReason else { return String(localized: "Unavailable") }
            return String(localized: "Unavailable · \(reason)")
        }
        let weekly = String(localized: "\(WatchFormat.percent(remaining)) of the weekly allowance remaining")
        switch freshness {
        case .live: return weekly
        case .stale: return String(localized: "\(weekly), stale")
        case .unavailable: return String(localized: "Unavailable")
        }
    }
}
