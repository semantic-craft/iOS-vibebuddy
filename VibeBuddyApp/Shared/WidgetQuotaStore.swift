import Foundation
import VibeBuddyKit
import WidgetKit

/// The allowance as this phone last knew it, mirrored for the quota widgets'
/// separate process. The Usage page reads the live store; a widget only has
/// this copy, so it carries what the widget needs to say how old it is and
/// whether the Mac was still reachable when it was written (PLAN §2.3).
struct PhoneQuotaSnapshot: Codable, Equatable {
    var quotas: [ProviderQuota]
    var macName: String?
    /// False once the phone saw the Mac drop; the widget fades on it.
    var relayLive: Bool
    var savedAt: Date
    var isDemo: Bool

    /// The same reading, whenever it was written: the save gate.
    func sameReading(as other: PhoneQuotaSnapshot) -> Bool {
        quotas == other.quotas && macName == other.macName
            && relayLive == other.relayLive && isDemo == other.isDemo
    }
}

/// App Group bridge for the quota widgets, beside `WidgetSnapshotStore`.
/// Writes only when the reading changed: a paired Mac sends a snapshot every
/// few seconds, and WidgetKit budgets how often a timeline may reload.
enum WidgetQuotaStore {
    static let providerKind = "PhoneQuotaProvider"
    static let overviewKind = "PhoneQuotaOverview"
    static let key = "provider-quota-snapshot"

    static var shared: UserDefaults? { UserDefaults(suiteName: WidgetSnapshotStore.appGroup) }

    static func load(from defaults: UserDefaults? = shared) -> PhoneQuotaSnapshot? {
        guard let data = defaults?.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(PhoneQuotaSnapshot.self, from: data)
    }

    /// Returns whether anything was written (and the widgets asked to reload).
    @discardableResult
    static func save(_ snapshot: PhoneQuotaSnapshot, to defaults: UserDefaults? = shared,
                     reload: () -> Void = reloadTimelines) -> Bool {
        guard let defaults else { return false }
        if let previous = load(from: defaults), previous.sameReading(as: snapshot) { return false }
        guard let data = try? JSONEncoder().encode(snapshot) else { return false }
        defaults.set(data, forKey: key)
        reload()
        return true
    }

    /// The Mac dropped: keep the numbers, stop calling them live.
    @discardableResult
    static func markRelayOffline(in defaults: UserDefaults? = shared, now: Date = Date(),
                                 reload: () -> Void = reloadTimelines) -> Bool {
        guard var snapshot = load(from: defaults), snapshot.relayLive else { return false }
        snapshot.relayLive = false
        snapshot.savedAt = now
        return save(snapshot, to: defaults, reload: reload)
    }

    @discardableResult
    static func clear(in defaults: UserDefaults? = shared, reload: () -> Void = reloadTimelines) -> Bool {
        guard let defaults, defaults.data(forKey: key) != nil else { return false }
        defaults.removeObject(forKey: key)
        reload()
        return true
    }

    static func reloadTimelines() {
        WidgetCenter.shared.reloadTimelines(ofKind: providerKind)
        WidgetCenter.shared.reloadTimelines(ofKind: overviewKind)
    }
}
