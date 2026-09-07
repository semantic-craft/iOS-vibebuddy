import Foundation
import Testing
@testable import VibeBuddyKit

@Suite("ProviderQuota displayWindow")
struct ProviderQuotaDisplayWindowTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("Weekly wins when present")
    func prefersWeekly() {
        let quota = ProviderQuota(
            provider: .codex,
            weeklyRemainingPercent: 68,
            weeklyWindowDurationMinutes: 10_080,
            shortWindowRemainingPercent: 84,
            shortWindowDurationMinutes: 300,
            otherWindows: [
                QuotaWindow(remainingPercent: 60, durationMinutes: 43_200, resetsAt: nil, observedAt: now)
            ],
            observedAt: now
        )
        #expect(quota.displayWindow(preferring: .weekly).remainingPercent == 68)
        #expect(quota.displayWindow(preferring: .short).remainingPercent == 84)
    }

    @Test("Falls back to short when weekly is missing")
    func fallsBackToShort() {
        let quota = ProviderQuota(
            provider: .codex,
            shortWindowRemainingPercent: 84,
            shortWindowDurationMinutes: 300,
            otherWindows: [
                QuotaWindow(remainingPercent: 60, durationMinutes: 43_200, resetsAt: nil, observedAt: now)
            ],
            observedAt: now
        )
        #expect(quota.displayWindow(preferring: .weekly).remainingPercent == 84)
    }

    @Test("Falls back to first usable otherWindows for monthly Cursor/Grok periods")
    func fallsBackToOtherWindows() {
        let other = QuotaWindow(
            remainingPercent: 60,
            durationMinutes: 43_200,
            resetsAt: now.addingTimeInterval(86_400),
            observedAt: now
        )
        let quota = ProviderQuota(
            provider: .cursor,
            otherWindows: [other],
            observedAt: now
        )
        #expect(quota.window(.weekly).remainingPercent == nil)
        #expect(quota.freshness(now: now) == .live)
        let display = quota.displayWindow(preferring: .weekly)
        #expect(display.remainingPercent == 60)
        #expect(display.currentRemainingPercent(now: now) == 60)
        #expect(display.status(now: now) == .live)
        #expect(quota.displayWindow(preferring: .short).remainingPercent == 60)
    }

    @Test("Relay cache state applies to monthly fallback")
    func cachedMonthlyFallback() {
        var quota = ProviderQuota(provider: .cursor, otherWindows: [
            QuotaWindow(remainingPercent: 60, durationMinutes: 43200, resetsAt: nil, observedAt: now)
        ], observedAt: now)
        quota.isCached = true
        #expect(quota.displayWindow().status(now: now) == .stale)
    }

    @Test("Unavailable stays unavailable when nothing is usable")
    func unavailableWhenEmpty() {
        let quota = ProviderQuota.unavailable(.cursor, reason: "Collection is turned off")
        #expect(quota.displayWindow(preferring: .weekly).remainingPercent == nil)
        #expect(quota.displayWindow(preferring: .weekly).status(now: now) == .unavailable)
    }
}
