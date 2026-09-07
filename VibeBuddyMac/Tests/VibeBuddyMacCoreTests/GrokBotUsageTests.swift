import Foundation
import Testing
@testable import VibeBuddyMacCore

@Suite("Grok Bot allowance")
struct GrokBotUsageTests {
    private let now = Date(timeIntervalSince1970: 1_789_000_000)

    @Test("Real observed response normalizes to a distinct weekly allowance")
    func observedResponse() throws {
        let sample = try GrokBotUsageDecoder.decode(Data(#"{"usagePercent":10.650043,"hasAvailableUsage":true,"nextResetTimestampUtc":"2026-09-13T23:21:36.519Z","grokPlanLabel":"Grok Bot Plan"}"#.utf8), fetchedAt: now)
        #expect(sample.provider == .grokBot)
        #expect(sample.primary?.usedPercent == 11)
        #expect(sample.primary?.windowDurationMinutes == 10_080)
        #expect(sample.primary?.resetsAt == CursorUsageSummaryDecoder.parseTimestamp("2026-09-13T23:21:36.519Z"))
        #expect(sample.hasAvailableUsage == true)
    }

    @Test("Missing and non-personal percentages never become full personal allowance", arguments: [
        #"{"hasAvailableUsage":true}"#,
        #"{"usagePercent":0,"includedLimitZero":true}"#,
        #"{"usagePercent":0,"usesPooledEnterpriseAllowance":true}"#
    ])
    func unavailablePercentage(_ json: String) throws {
        let snapshot = try GrokBotUsageDecoder.decode(Data(json.utf8), fetchedAt: now)
        #expect(snapshot.primary == nil)
        #expect(snapshot.usageDetail != nil)
    }

    @Test("Account switch during network read discards the response")
    func switchedAccount() async throws {
        let provider = GrokBotUsageProvider(account: {
            GrokBotLocalAccount(accessToken: "test", accountScope: "original", accountIdentity: "original", accountLabel: "test account", teamID: nil)
        }, activeIdentity: { "different" }, transport: QuotaTransport(status: 200))
        await #expect(throws: AccountUsageError.notLoggedIn) { try await provider.fetch() }
    }

    @Test("Collector preserves stale quota only for the same account", arguments: [true, false])
    func foreignCache(sameAccount: Bool) async throws {
        var cached = AccountUsageSnapshot(provider: .grokBot, planType: nil,
            primary: AccountUsageWindow(kind: .primary, usedPercent: 11, windowDurationMinutes: 10_080,
                resetsAt: now.addingTimeInterval(3600)), secondary: nil,
            lifetimeTokens: nil, latestDailyTokens: nil, fetchedAt: now)
        cached.accountIdentity = "account-A"
        let provider = GrokBotUsageProvider(account: { throw AccountUsageError.notLoggedIn },
            activeIdentity: { sameAccount ? "account-A" : "account-B" }, transport: QuotaTransport(status: 200))
        let collector = AccountUsageCollector(provider: provider, cache: QuotaCache(snapshot: cached), enabled: true)
        let initial = await collector.bootstrap(now: now)
        #expect((initial.snapshot != nil) == sameAccount)
        let failure = await collector.refresh(now: now)
        #expect((failure.snapshot != nil) == sameAccount)
        #expect(failure.isStale == sameAccount)
        #expect(failure.unavailableReason == .notLoggedIn)
    }

    @Test("Denied request becomes unavailable, never a zero-percent sample")
    func deniedRequest() async throws {
        let provider = GrokBotUsageProvider(account: {
            GrokBotLocalAccount(accessToken: "test", accountScope: "original", accountIdentity: "original", accountLabel: "test account", teamID: nil)
        }, activeIdentity: { "original" }, transport: QuotaTransport(status: 403))
        await #expect(throws: AccountUsageError.notLoggedIn) { try await provider.fetch() }
    }
}

private struct QuotaTransport: CursorUsageTransport {
    let status: Int
    func cursorData(for request: URLRequest) async throws -> (Data, URLResponse) {
        #expect(request.url?.path == "/aiserver.v1.DashboardService/GetSandUsageStatus")
        #expect(request.value(forHTTPHeaderField: "x-ghost-mode") == "true")
        return (Data("{}".utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

private struct QuotaCache: AccountUsageCaching {
    let snapshot: AccountUsageSnapshot
    func load() async -> AccountUsageSnapshot? { snapshot }
    func save(_ snapshot: AccountUsageSnapshot, permit: AccountUsageCacheCommitPermit) async throws {}
}
