import Foundation
import VibeBuddyKit

/// Turns what a provider's collector knows into the one normalized quota value
/// the rest of the system carries.
///
/// This is where a provider's own convention stops mattering: `usedPercent`
/// becomes percent remaining exactly once, here, on the Mac, while the
/// provider's shape is still in scope. Everything downstream — the wire
/// snapshot, the iPhone, the Watch — deals only in remaining.
public extension ProviderQuota {
    /// Every provider the app knows about, in a stable order, projected from
    /// whatever its own collector currently knows.
    ///
    /// One entry per provider, always: a provider that is failing, still
    /// loading, or switched off stays explicitly present and says why, instead
    /// of vanishing from the list and leaving the wrist to guess. Because each
    /// entry is built only from that provider's own state, a broken Claude
    /// cannot change what Codex reports, and vice versa.
    static func all(from states: [AccountUsageProvider: AccountUsageState]) -> [ProviderQuota] {
        AccountUsageProvider.allCases.map { ProviderQuota(states[$0] ?? .disabled, provider: $0) }
    }

    /// A window at least this long counts as the weekly allowance. Providers
    /// describe their windows by duration rather than by name, so the weekly one
    /// is identified by how long it lasts, not by which slot it arrived in.
    static let weeklyWindowMinimumMinutes = 24 * 60

    init(_ state: AccountUsageState, provider: AccountUsageProvider) {
        guard let snapshot = state.snapshot else {
            // Nothing usable has ever arrived. That is unavailable, and the
            // reason is the collector's own diagnosis.
            self = .unavailable(
                provider,
                reason: (state.unavailableReason ?? .notYetLoaded).displayText(provider: provider))
            return
        }

        let windows = snapshot.windows
        let weekly = windows
            .filter { ($0.windowDurationMinutes ?? 0) >= Self.weeklyWindowMinimumMinutes }
            .max { ($0.windowDurationMinutes ?? 0) < ($1.windowDurationMinutes ?? 0) }
        let short = windows
            .filter { ($0.windowDurationMinutes ?? Int.max) < Self.weeklyWindowMinimumMinutes }
            .max { ($0.windowDurationMinutes ?? 0) < ($1.windowDurationMinutes ?? 0) }

        // A provider is available only when its weekly window is: a short window
        // on its own says nothing about the week someone is planning.
        let weeklyRemaining = Self.remaining(fromUsedPercent: weekly?.usedPercent)
        let reason: String? = weeklyRemaining == nil
            ? (state.unavailableReason ?? .incompatibleFormat).displayText(provider: provider)
            : nil

        self.init(
            provider: provider,
            weeklyRemainingPercent: weeklyRemaining,
            weeklyResetsAt: weekly?.resetsAt,
            shortWindowRemainingPercent: Self.remaining(fromUsedPercent: short?.usedPercent),
            shortWindowResetsAt: short?.resetsAt,
            observedAt: weeklyRemaining == nil ? nil : snapshot.fetchedAt,
            unavailableReason: reason)
    }
}
