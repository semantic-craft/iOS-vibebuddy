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
    func shortWindowAloneIsUnavailable() {
        let state = AccountUsageState.available(
            snapshot(primary: window(.primary, used: 16, minutes: 300)), nextRefreshAt: nil)
        let result = quota(state)
        #expect(result.weeklyRemainingPercent == nil)
        #expect(result.shortWindowRemainingPercent == 84)
        #expect(result.observedAt == nil)
        #expect(result.freshness(now: fetchedAt) == .unavailable)
        #expect(result.unavailableReason == "Codex returned an unsupported format")
    }

    @Test("A window with no duration cannot be claimed as the week")
    func missingDurationIsNotWeekly() {
        let state = AccountUsageState.available(
            snapshot(primary: window(.primary, used: 32, minutes: nil)), nextRefreshAt: nil)
        #expect(quota(state).weeklyRemainingPercent == nil)
        #expect(quota(state).freshness(now: fetchedAt) == .unavailable)
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
        #expect(result.freshness(now: fetchedAt.addingTimeInterval(899)) == .live)
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
}
