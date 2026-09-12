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

    /// `now` decides which Grok windows have already expired. It is injectable
    /// so a fixture with a fixed period does not start failing the day it ages
    /// past the wall clock.
    init(_ state: AccountUsageState, provider: AccountUsageProvider, now: Date = Date()) {
        guard state.collectionEnabled else {
            self = .unavailable(provider, reason: AccountUsageUnavailableReason.collectionDisabled.displayText(provider: provider))
            return
        }
        guard let snapshot = state.snapshot?.excludingExpiredGrokWindows(at: now) else {
            self = .unavailable(provider,
                reason: (state.unavailableReason ?? .notYetLoaded).displayText(provider: provider))
            return
        }
        let weekly = snapshot.quotaWindows.first { $0.windowDurationMinutes == 10080 }
        let short = snapshot.quotaWindows.filter {
            guard let minutes = $0.windowDurationMinutes else { return false }
            return minutes > 0 && minutes < 1440
        }.max { ($0.windowDurationMinutes ?? 0) < ($1.windowDurationMinutes ?? 0) }
        let project: (AccountUsageWindow) -> QuotaWindow = { window in
            QuotaWindow(remainingPercent: Self.remaining(fromUsedPercent: window.usedPercent),
                        durationMinutes: window.windowDurationMinutes, resetsAt: window.resetsAt,
                        observedAt: snapshot.fetchedAt, isCached: state.isStale, label: window.label)
        }
        let others = snapshot.quotaWindows.filter {
            // Preserve independent pools even when they share a duration.
            $0.kind != weekly?.kind && $0.kind != short?.kind
        }.map(project)
        // A model-scoped week or a Spark window is a subdivision of the same
        // allowance, not a pool of its own, so it stays out of `otherWindows`:
        // that slot is what the Watch strip and the widgets fall back to when
        // weekly and short are missing, and "Fable only" must never become the
        // number the wrist reads as Claude's remaining.
        let scoped = (snapshot.extraWindows ?? []).map(project)
        let weeklyRemaining = Self.remaining(fromUsedPercent: weekly?.usedPercent)
        let shortRemaining = Self.remaining(fromUsedPercent: short?.usedPercent)
        let usable = weeklyRemaining != nil || shortRemaining != nil
            || others.contains { $0.remainingPercent != nil }
            || scoped.contains { $0.remainingPercent != nil }
        self.init(provider: provider, accountLabel: snapshot.accountLabel,
                  weeklyRemainingPercent: weeklyRemaining, weeklyResetsAt: weekly?.resetsAt,
                  weeklyWindowDurationMinutes: weekly?.windowDurationMinutes,
                  shortWindowRemainingPercent: shortRemaining, shortWindowResetsAt: short?.resetsAt,
                  shortWindowDurationMinutes: short?.windowDurationMinutes,
                  otherWindows: others.isEmpty ? nil : others,
                  scopedWindows: scoped.isEmpty ? nil : scoped,
                  credits: snapshot.credits,
                  spend: snapshot.spend,
                  observedAt: usable || provider == .grokBot ? snapshot.fetchedAt : nil,
                  unavailableReason: state.unavailableReason?.displayText(provider: provider)
                    ?? (usable ? nil : snapshot.usageDetail)
                    ?? (usable ? nil : (provider == .grok ? AccountUsageUnavailableReason.unknown : .incompatibleFormat).displayText(provider: provider)),
                  isCached: state.isStale)
        weeklyLabel = weekly?.label
        shortWindowLabel = short?.label
    }
}
