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

    init(_ state: AccountUsageState, provider: AccountUsageProvider) {
        guard state.collectionEnabled else {
            self = .unavailable(provider, reason: AccountUsageUnavailableReason.collectionDisabled.displayText(provider: provider))
            return
        }
        guard let snapshot = state.snapshot else {
            self = .unavailable(provider,
                reason: (state.unavailableReason ?? .notYetLoaded).displayText(provider: provider))
            return
        }
        let weekly = snapshot.windows.first { $0.windowDurationMinutes == 10080 }
        let short = snapshot.windows.filter {
            guard let minutes = $0.windowDurationMinutes else { return false }
            return minutes > 0 && minutes < 1440
        }.max { ($0.windowDurationMinutes ?? 0) < ($1.windowDurationMinutes ?? 0) }
        let others = snapshot.windows.filter {
            guard let minutes = $0.windowDurationMinutes else { return true }
            return minutes != 10080 && !(minutes > 0 && minutes < 1440)
        }.map {
            QuotaWindow(remainingPercent: Self.remaining(fromUsedPercent: $0.usedPercent),
                        durationMinutes: $0.windowDurationMinutes, resetsAt: $0.resetsAt,
                        observedAt: snapshot.fetchedAt, isCached: state.isStale)
        }
        let weeklyRemaining = Self.remaining(fromUsedPercent: weekly?.usedPercent)
        let shortRemaining = Self.remaining(fromUsedPercent: short?.usedPercent)
        let usable = weeklyRemaining != nil || shortRemaining != nil || others.contains { $0.remainingPercent != nil }
        self.init(provider: provider,
                  weeklyRemainingPercent: weeklyRemaining, weeklyResetsAt: weekly?.resetsAt,
                  weeklyWindowDurationMinutes: weekly?.windowDurationMinutes,
                  shortWindowRemainingPercent: shortRemaining, shortWindowResetsAt: short?.resetsAt,
                  shortWindowDurationMinutes: short?.windowDurationMinutes,
                  otherWindows: others.isEmpty ? nil : others,
                  observedAt: usable ? snapshot.fetchedAt : nil,
                  unavailableReason: state.unavailableReason?.displayText(provider: provider)
                    ?? (usable ? nil : AccountUsageUnavailableReason.incompatibleFormat.displayText(provider: provider)),
                  isCached: state.isStale)
    }
}
