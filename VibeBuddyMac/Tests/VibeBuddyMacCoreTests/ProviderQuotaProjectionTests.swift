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

    @Test("A fully spent week is 0% remaining, not unavailable")
    func fullySpentIsZeroNotMissing() {
        let state = AccountUsageState.available(
            snapshot(primary: window(.primary, used: 100, minutes: 10_080)), nextRefreshAt: nil)
        #expect(quota(state).weeklyRemainingPercent == 0)
        #expect(quota(state).unavailableReason == nil)
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

    @Test("Every collector failure keeps its own diagnosis")
    func failuresKeepTheirReason() {
        let cases: [(AccountUsageUnavailableReason, String)] = [
            (.notLoggedIn, "Codex is not signed in"),
            (.providerUnavailable, "Codex CLI is unavailable"),
            (.timedOut, "Usage refresh timed out"),
            (.incompatibleFormat, "Codex returned an unsupported format"),
            (.offline, "Offline"),
            (.rateLimited, "Usage service is rate limited"),
        ]
        for (reason, text) in cases {
            let state = AccountUsageState.unavailable(reason, lastAttemptAt: fetchedAt, nextRefreshAt: nil)
            #expect(quota(state).unavailableReason == text)
            #expect(quota(state).weeklyRemainingPercent == nil)
        }
    }

    @Test("Turning collection off is an explicit unavailable, not a silent freeze")
    func disabledCollectionIsUnavailable() {
        let result = quota(.disabled)
        #expect(result.weeklyRemainingPercent == nil)
        #expect(result.unavailableReason == "Collection is turned off")
        #expect(result.freshness(now: fetchedAt) == .unavailable)
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

    /// The `/usage` envelope the CLI actually writes, wrapped the way the
    /// adapter receives it. Recorded output, never the tester's own account.
    private func claudeUsage(_ body: String, isError: Bool = false) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["is_error": isError, "result": body])
    }

    private func claudeQuota(_ body: String, now: Date) throws -> ProviderQuota {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Asia/Shanghai"))
        let decoded = try ClaudeUsageResponseDecoder.decode(
            try claudeUsage(body), fetchedAt: now, calendar: calendar)
        return ProviderQuota(.available(decoded, nextRefreshAt: nil), provider: .claude)
    }

    @Test("A recorded Claude /usage reading becomes the same normalized quota as Codex")
    func claudeReadingNormalizes() throws {
        let now = Date(timeIntervalSince1970: 1_788_400_000)
        let result = try claudeQuota("""
        You are currently using your subscription to power your Claude Code usage

        Current session: 43% used · resets Sep 3 at 2:30pm (Asia/Shanghai)
        Current week (all models): 58% used · resets Sep 5 at 8pm (Asia/Shanghai)
        Current week (Fable): 58% used · resets Sep 5 at 8pm (Asia/Shanghai)
        """, now: now)

        #expect(result.provider == .claude)
        #expect(result.weeklyRemainingPercent == 42)
        #expect(result.shortWindowRemainingPercent == 57)
        #expect(result.weeklyResetsAt != nil)
        #expect(result.observedAt == now)
        #expect(result.freshness(now: now) == .live)
    }

    @Test("A Claude reading with only the session window says nothing about the week")
    func claudeWithoutWeeklyIsAvailable() throws {
        let now = Date(timeIntervalSince1970: 1_788_400_000)
        let result = try claudeQuota(
            "Current session: 43% used · resets Sep 3 at 2:30pm (Asia/Shanghai)", now: now)
        #expect(result.weeklyRemainingPercent == nil)
        #expect(result.shortWindowRemainingPercent == 57)
        #expect(result.freshness(now: now) == .live)
        #expect(result.unavailableReason == nil)
    }

    @Test("A signed-out or malformed Claude reply never becomes a number")
    func claudeFailuresNeverBecomeNumbers() throws {
        #expect(throws: AccountUsageError.notLoggedIn) {
            try ClaudeUsageResponseDecoder.decode(
                try claudeUsage("You are not logged in", isError: true), fetchedAt: fetchedAt)
        }
        #expect(throws: AccountUsageError.incompatibleFormat) {
            try ClaudeUsageResponseDecoder.decode(Data("not json".utf8), fetchedAt: fetchedAt)
        }
        #expect(throws: AccountUsageError.incompatibleFormat) {
            try ClaudeUsageResponseDecoder.decode(
                try claudeUsage("Nothing about usage here"), fetchedAt: fetchedAt)
        }
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
