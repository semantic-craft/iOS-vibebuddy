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
        case .needsResponse: return "Needs you"
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

extension WatchConnection {
    /// A different symbol per broken link, so the footer says which one at a
    /// glance without reading the words.
    var symbolName: String {
        switch self {
        case .live: return "iphone.gen3"
        case .macDisconnected: return "desktopcomputer.trianglebadge.exclamationmark"
        case .phoneDisconnected: return "iphone.gen3.slash"
        case .watchUnreachable: return "antenna.radiowaves.left.and.right.slash"
        case .noData: return "iphone.gen3.slash"
        }
    }

    /// The banner above the numbers. Nothing is shown while the state is a live
    /// reading, and the no-data screen explains itself.
    var bannerTitle: LocalizedStringResource? {
        switch self {
        case .live, .noData: return nil
        case .macDisconnected: return "Can't reach your Mac"
        case .phoneDisconnected: return "iPhone stopped updating"
        case .watchUnreachable: return "Out of range of your iPhone"
        }
    }

    /// What to do about it, for the screen with room to say so.
    var advice: LocalizedStringResource? {
        switch self {
        case .live, .noData: return nil
        case .macDisconnected:
            return "Your iPhone can't reach your Mac, so this is the last thing it knew."
        case .phoneDisconnected:
            return "Your iPhone is nearby but hasn't sent anything in a while. Open vibebuddy on your iPhone."
        case .watchUnreachable:
            return "Your Watch has lost your iPhone, so this is the last thing it knew."
        }
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
    static func windowName(_ window: QuotaWindow) -> String {
        guard let minutes = window.durationMinutes else { return String(localized: "Window duration unknown") }
        if minutes == 10080 { return String(localized: "Weekly remaining") }
        if minutes % 1440 == 0 { return String(localized: "\(minutes / 1440)-day window") }
        if minutes % 60 == 0 { return String(localized: "\(minutes / 60)-hour window") }
        return String(localized: "\(minutes)-minute window")
    }

    static func summary(_ quota: ProviderQuota, freshness: QuotaFreshness, now: Date) -> String {
        QuotaWindowKind.allCases.map { kind in
            let reading = quota.window(kind)
            let name = kind == .weekly ? String(localized: "Weekly remaining") : windowName(reading)
            switch reading.status(now: now) {
            case .awaitingReset: return name + ": " + String(localized: "Reset reached · awaiting update")
            case .unavailable: return name + ": " + String(localized: "Unavailable")
            case .live, .stale:
                let value = reading.currentRemainingPercent(now: now).map(WatchFormat.percent) ?? "—"
                return name + ": " + value + (reading.status(now: now) == .stale ? ", " + String(localized: "Cached reading") : "")
            }
        }.joined(separator: "; ")
    }
}
