import Testing
import Foundation
import VibeBuddyKit
@testable import VibeBuddyMacCore

@Suite("Provider quota projection")
struct ProviderQuotaProjectionTests {

    private let fetchedAt = Date(timeIntervalSince1970: 1_800_000_000)

    private func window(_ kind: AccountUsageWindowKind, used: Int,
                        minutes: Int?, resetsIn: TimeInterval? = nil) -> AccountUsageWindow {
        AccountUsageWindow(kind: kind, usedPercent: used, windowDurationMinutes: minutes,
                           resetsAt: resetsIn.map { fetchedAt.addingTimeInterval($0) })
    }

    private func snapshot(primary: AccountUsageWindow?,
                          secondary: AccountUsageWindow? = nil) -> AccountUsageSnapshot {
        AccountUsageSnapshot(provider: .codex, planType: "pro", primary: primary,
                             secondary: secondary, lifetimeTokens: nil,
                             latestDailyTokens: nil, fetchedAt: fetchedAt)
    }

    private func quota(_ state: AccountUsageState) -> ProviderQuota {
        ProviderQuota(state, provider: .codex)
    }

    @Test("unknown Grok included allowance cannot become extra-usage quota or an alert")
    func grokExtraUsageIsSeparate() {
        var bill = snapshot(primary: nil, secondary: window(.secondary, used: 95, minutes: 10080))
        bill.provider = .grok
        let state = AccountUsageState.available(bill, nextRefreshAt: nil)
        let result = ProviderQuota(state, provider: .grok)
        #expect(result.weeklyRemainingPercent == nil)
        #expect(result.otherWindows == nil)
        var monitor = AccountUsageAlertMonitor()
        var baseline = bill
        baseline.secondary?.usedPercent = 10
        _ = monitor.newlyCrossed(in: .available(baseline, nextRefreshAt: nil), thresholdPercent: 90)
        #expect(monitor.newlyCrossed(in: state, thresholdPercent: 90).isEmpty)
    }

    @Test("Independent pools retain labels and balances even at the same duration")
    func independentPools() throws {
        let primary = AccountUsageWindow(kind: .primary, usedPercent: 20,
            windowDurationMinutes: 10080, resetsAt: nil, label: "Plan allowance")
        let secondary = AccountUsageWindow(kind: .secondary, usedPercent: 75,
            windowDurationMinutes: 10080, resetsAt: nil, label: "On-demand")
        let result = quota(.available(snapshot(primary: primary, secondary: secondary), nextRefreshAt: nil))
        #expect(result.window(.weekly).label == "Plan allowance")
        #expect(result.weeklyRemainingPercent == 80)
        #expect(result.otherWindows?.count == 1)
        #expect(result.otherWindows?.first?.label == "On-demand")
        #expect(result.otherWindows?.first?.remainingPercent == 25)
        let roundTrip = try JSONDecoder().decode(ProviderQuota.self, from: JSONEncoder().encode(result))
        #expect(roundTrip == result)
    }

    // MARK: normalization

    @Test("Consumed becomes remaining exactly once")
    func consumedBecomesRemaining() {
        let state = AccountUsageState.available(
            snapshot(primary: window(.primary, used: 16, minutes: 300, resetsIn: 3_600),
                     secondary: window(.secondary, used: 32, minutes: 10_080, resetsIn: 86_400)),
            nextRefreshAt: nil)
        let result = quota(state)
        #expect(result.weeklyRemainingPercent == 68)
        #expect(result.shortWindowRemainingPercent == 84)
        #expect(result.weeklyResetsAt == fetchedAt.addingTimeInterval(86_400))
        #expect(result.shortWindowResetsAt == fetchedAt.addingTimeInterval(3_600))
        #expect(result.observedAt == fetchedAt)
        #expect(result.unavailableReason == nil)
        #expect(result.freshness(now: fetchedAt) == .live)
    }

    @Test("The weekly window is the long one, whichever slot it arrived in")
    func weeklyIsIdentifiedByDurationNotSlot() {
        // Some payloads put the week first; the meaning is in the duration.
        let swapped = AccountUsageState.available(
            snapshot(primary: window(.primary, used: 32, minutes: 10_080),
                     secondary: window(.secondary, used: 16, minutes: 300)),
            nextRefreshAt: nil)
        #expect(quota(swapped).weeklyRemainingPercent == 68)
        #expect(quota(swapped).shortWindowRemainingPercent == 84)
    }

    @Test("An out-of-range percentage is malformed, never clamped into a number")
    func outOfRangeIsMalformed() {
        #expect(ProviderQuota.remaining(fromUsedPercent: 140) == nil)
        #expect(ProviderQuota.remaining(fromUsedPercent: -5) == nil)
        #expect(ProviderQuota.remaining(fromUsedPercent: nil) == nil)
        #expect(ProviderQuota.remaining(fromUsedPercent: 0) == 100)
        #expect(ProviderQuota.remaining(fromUsedPercent: 100) == 0)
    }

    // MARK: unavailable

    @Test("A short window alone says nothing about the week")
    func shortWindowAloneIsAvailable() {
        let state = AccountUsageState.available(
            snapshot(primary: window(.primary, used: 16, minutes: 300)), nextRefreshAt: nil)
        let result = quota(state)
        #expect(result.weeklyRemainingPercent == nil)
        #expect(result.shortWindowRemainingPercent == 84)
        #expect(result.observedAt == fetchedAt)
        #expect(result.freshness(now: fetchedAt) == .live)
        #expect(result.unavailableReason == nil)
    }

    @Test("A window with no duration cannot be claimed as the week")
    func missingDurationIsNotWeekly() {
        let state = AccountUsageState.available(
            snapshot(primary: window(.primary, used: 32, minutes: nil)), nextRefreshAt: nil)
        #expect(quota(state).weeklyRemainingPercent == nil)
        #expect(quota(state).window(.weekly).status(now: fetchedAt) == .unavailable)
        #expect(quota(state).otherWindows?.first?.remainingPercent == 68)
    }

    @Test("A never-loaded source is unavailable, not stale")
    func neverLoadedIsUnavailable() {
        let result = quota(.unavailable(.notYetLoaded, lastAttemptAt: nil, nextRefreshAt: nil))
        #expect(result.freshness(now: fetchedAt) == .unavailable)
        #expect(result.unavailableReason == "Waiting for the first refresh")
    }

    // MARK: freshness

    @Test("A previously valid value stays visible and turns stale at 15 minutes")
    func staleKeepsTheLastValue() {
        let state = AccountUsageState.stale(
            snapshot(primary: window(.primary, used: 32, minutes: 10_080)),
            reason: .cachedData, lastAttemptAt: fetchedAt, nextRefreshAt: nil)
        let result = quota(state)
        #expect(result.weeklyRemainingPercent == 68)
        #expect(result.freshness(now: fetchedAt.addingTimeInterval(899)) == .stale)
        #expect(result.freshness(now: fetchedAt.addingTimeInterval(900)) == .stale)
    }

    // MARK: the real decoder, on fixtures

    @Test("A recorded app-server payload becomes a normalized quota")
    func recordedPayloadNormalizes() throws {
        let rateLimits = Data("""
        {"result":{"rateLimits":{"planType":"pro",
          "primary":{"usedPercent":16,"windowDurationMins":300,"resetsAt":1800003600},
          "secondary":{"usedPercent":32,"windowDurationMins":10080,"resetsAt":1800086400}}}}
        """.utf8)
        let usage = Data(#"{"result":{"summary":{"lifetimeTokens":123}}}"#.utf8)
        let decoded = try CodexUsageResponseDecoder.decode(
            rateLimitsResponse: rateLimits, usageResponse: usage, fetchedAt: fetchedAt)
        let result = ProviderQuota(.available(decoded, nextRefreshAt: nil), provider: .codex)
        #expect(result.weeklyRemainingPercent == 68)
        #expect(result.shortWindowRemainingPercent == 84)
        #expect(result.provider == .codex)
    }

    @Test("A signed-out app-server reply never becomes a number")
    func signedOutPayloadIsUnavailable() {
        let rateLimits = Data(#"{"error":{"code":-32000,"message":"not logged in"}}"#.utf8)
        let usage = Data(#"{"result":{"summary":{}}}"#.utf8)
        #expect(throws: AccountUsageError.notLoggedIn) {
            try CodexUsageResponseDecoder.decode(
                rateLimitsResponse: rateLimits, usageResponse: usage, fetchedAt: fetchedAt)
        }
    }

    @Test("Malformed JSON never becomes a number")
    func malformedPayloadIsUnavailable() {
        #expect(throws: AccountUsageError.incompatibleFormat) {
            try CodexUsageResponseDecoder.decode(
                rateLimitsResponse: Data("not json".utf8),
                usageResponse: Data("not json".utf8), fetchedAt: fetchedAt)
        }
    }

    // MARK: Claude, on the same contract

    /// Claude's allowance reaches the app one way: the `rate_limits` block of
    /// the status line document the CLI writes on every event. Recorded shape,
    /// never the tester's own account.
    private func claudeQuota(_ limits: [String: Any], now: Date) throws -> ProviderQuota {
        let document: [String: Any] = ["session_id": "s1", "rate_limits": limits]
        let sample = try #require(StatusLineSample.decode(document))
        let snapshot = try #require(sample.usageSnapshot(fetchedAt: now))
        return ProviderQuota(.available(snapshot, nextRefreshAt: nil), provider: .claude)
    }

    @Test("A recorded Claude status-line reading becomes the same normalized quota as Codex")
    func claudeReadingNormalizes() throws {
        let now = Date(timeIntervalSince1970: 1_788_400_000)
        let result = try claudeQuota([
            "five_hour": ["used_percentage": 43, "resets_at": 1_788_410_000],
            "seven_day": ["used_percentage": 58, "resets_at": 1_788_900_000],
            "seven_day_fable": ["used_percentage": 58, "resets_at": 1_788_900_000],
        ], now: now)

        #expect(result.provider == .claude)
        #expect(result.weeklyRemainingPercent == 42)
        #expect(result.shortWindowRemainingPercent == 57)
        #expect(result.weeklyResetsAt != nil)
        #expect(result.observedAt == now)
        #expect(result.freshness(now: now) == .live)
        // A model-scoped week is a subdivision of the same allowance, so it
        // must not reach the slot the Watch and the widgets fall back to.
        #expect(result.otherWindows == nil)
        #expect(result.scopedWindows?.first?.label == "Fable only")
    }

    @Test("A missing or out-of-range Claude window never becomes a number")
    func claudeFailuresNeverBecomeNumbers() throws {
        let empty: [String: Any] = ["session_id": "s1"]
        #expect(StatusLineSample.decode(empty)?.usageSnapshot(fetchedAt: fetchedAt) == nil)

        let outOfRange: [String: Any] = ["session_id": "s1", "rate_limits": [
            "five_hour": ["used_percentage": 101],
            "seven_day": ["used_percentage": 58, "resets_at": 1_788_900_000],
        ]]
        let sample = try #require(StatusLineSample.decode(outOfRange))
        let snapshot = try #require(sample.usageSnapshot(fetchedAt: fetchedAt))
        // One malformed window cannot discard the other, and cannot read as 0%.
        #expect(snapshot.primary == nil)
        let quota = ProviderQuota(.available(snapshot, nextRefreshAt: nil), provider: .claude)
        #expect(quota.shortWindowRemainingPercent == nil)
        #expect(quota.weeklyRemainingPercent == 42)
    }

    // MARK: Cursor / Grok billing periods (#113 H3)

    @Test("A Cursor monthly billing window stays in otherWindows and is usable for display")
    func cursorMonthlyBillingProjectsToOtherWindows() throws {
        // Mid-cycle relative to usage-summary-plan-only (Aug→Sep 2026 billing window).
        let observed = ISO8601DateFormatter().date(from: "2026-08-15T12:00:00Z")!
        let url = try #require(Bundle.module.url(
            forResource: "usage-summary-plan-only",
            withExtension: "json",
            subdirectory: "Fixtures/cursor"
        ))
        let data = try Data(contentsOf: url)
        let snapshot = try CursorUsageSummaryDecoder.decode(data, fetchedAt: observed)
        let result = ProviderQuota(.available(snapshot, nextRefreshAt: nil), provider: .cursor)
        #expect(result.provider == .cursor)
        #expect(result.weeklyRemainingPercent == nil)
        #expect(result.shortWindowRemainingPercent == nil)
        #expect(result.otherWindows?.first?.remainingPercent == 60)
        #expect(result.otherWindows?.first?.durationMinutes == 31 * 24 * 60)
        #expect(result.observedAt == observed)
        #expect(result.freshness(now: observed) == .live)
        #expect(result.unavailableReason == nil)
        #expect(result.credits?.remaining == 1200)
        #expect(result.credits?.limit == 2000)
        // Watch/home surfaces must not show "Window unavailable" while live.
        let display = result.displayWindow(preferring: .weekly)
        #expect(display.remainingPercent == 60)
        #expect(display.currentRemainingPercent(now: observed) == 60)
        #expect(display.status(now: observed) == .live)
    }

    // MARK: both providers at once

    private func codexState(usedWeekly: Int) -> AccountUsageState {
        .available(snapshot(primary: window(.primary, used: usedWeekly, minutes: 10_080)),
                   nextRefreshAt: nil)
    }

    private func claudeState(usedWeekly: Int, fetchedAt: Date) -> AccountUsageState {
        .available(
            AccountUsageSnapshot(
                provider: .claude, planType: nil,
                primary: nil,
                secondary: AccountUsageWindow(kind: .secondary, usedPercent: usedWeekly,
                                              windowDurationMinutes: 10_080, resetsAt: nil),
                lifetimeTokens: nil, latestDailyTokens: nil, fetchedAt: fetchedAt),
            nextRefreshAt: nil)
    }

    @Test("Every provider reaches the snapshot, in a stable order, each from its own state")
    func bothProvidersProjected() {
        let quotas = ProviderQuota.all(from: [
            .codex: codexState(usedWeekly: 32),
            .claude: claudeState(usedWeekly: 58, fetchedAt: fetchedAt),
        ])
        #expect(quotas.map(\.provider) == AccountUsageProvider.allCases)
        #expect(quotas.first { $0.provider == .codex }?.weeklyRemainingPercent == 68)
        #expect(quotas.first { $0.provider == .claude }?.weeklyRemainingPercent == 42)
        #expect(quotas.first { $0.provider == .cursor }?.weeklyRemainingPercent == nil)
        #expect(quotas.first { $0.provider == .cursor }?.unavailableReason
                == "Collection is turned off")
    }

    @Test("A failing or disabled provider never changes what the other one reports")
    func oneProviderFailingLeavesTheOtherAlone() {
        let claudeBroken = ProviderQuota.all(from: [
            .codex: codexState(usedWeekly: 32),
            .claude: .unavailable(.notLoggedIn, lastAttemptAt: fetchedAt, nextRefreshAt: nil),
        ])
        #expect(claudeBroken.first { $0.provider == .codex }?.weeklyRemainingPercent == 68)
        #expect(claudeBroken.first { $0.provider == .claude }?.weeklyRemainingPercent == nil)
        #expect(claudeBroken.first { $0.provider == .claude }?.unavailableReason
                == "Claude is not signed in")

        let codexOff = ProviderQuota.all(from: [
            .codex: .disabled,
            .claude: claudeState(usedWeekly: 58, fetchedAt: fetchedAt),
        ])
        #expect(codexOff.first { $0.provider == .codex }?.unavailableReason
                == "Collection is turned off")
        #expect(codexOff.first { $0.provider == .claude }?.weeklyRemainingPercent == 42)
    }

    @Test("Each provider ages on its own clock, and both can be unavailable at once")
    func freshnessAndFailureAreIndependent() {
        let mixed = ProviderQuota.all(from: [
            .codex: codexState(usedWeekly: 32),
            .claude: claudeState(usedWeekly: 58, fetchedAt: fetchedAt.addingTimeInterval(-900)),
        ])
        #expect(mixed.first { $0.provider == .codex }?.freshness(now: fetchedAt) == .live)
        #expect(mixed.first { $0.provider == .claude }?.freshness(now: fetchedAt) == .stale)
        // A stale reading keeps its last number; it does not become zero.
        #expect(mixed.first { $0.provider == .claude }?.weeklyRemainingPercent == 42)

        // Nothing configured at all is still one explicit entry per provider,
        // not an empty list.
        let none = ProviderQuota.all(from: [:])
        #expect(none.count == AccountUsageProvider.allCases.count)
        #expect(none.allSatisfy { $0.unavailableReason == "Collection is turned off" })
    }
}
