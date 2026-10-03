import Foundation
import Testing
import VibeBuddyKit
@testable import VibeBuddyMacCore

@Suite("Antigravity account allowance")
struct AntigravityUsageProviderTests {
    @Test("independent model groups retain both windows and the wrist names each tightest window")
    func modelPools() throws {
        let now = Date(timeIntervalSince1970: 1_791_054_732)
        let json = #"{"status":"SUCCESS","command":{"data":{"groups":[{"name":"Gemini Models","buckets":[{"id":"gemini-weekly","window":"weekly","remaining_fraction":0.98999667,"reset_time":"2026-10-10T18:11:56Z"},{"id":"gemini-5h","window":"5h","remaining_fraction":0.98996967,"reset_time":"2026-10-03T23:11:56Z"}]},{"name":"Claude and GPT models","buckets":[{"id":"3p-weekly","window":"weekly","remaining_fraction":0.62370097,"reset_time":"2026-10-10T18:07:11Z"},{"id":"3p-5h","window":"5h","remaining_fraction":0.24930335,"reset_time":"2026-10-03T23:07:11Z"}]}]}}}"#
        let sample = try AntigravityUsageProvider.decode(Data(json.utf8), fetchedAt: now)
        #expect(sample.displayWindows.count == 4)
        #expect(sample.accountLabel == "CLI account")
        let quota = ProviderQuota(.available(sample, nextRefreshAt: nil), provider: .antigravity, now: now)
        let rows = quota.stripWindows(now: now)
        #expect(rows.count == 2)
        #expect(rows.first?.remainingPercent == 25)
        #expect(rows.first?.label == "Claude and GPT models · 5h")
        #expect(quota.poolReadings(now: now).first?.remainingPercent == 25)
        #expect(quota.independentWindows.count == 4)
        #expect(quota.stripWindows(now: now.addingTimeInterval(20_000)).first?.remainingPercent == 62)
        #expect(quota.freshness(now: now.addingTimeInterval(901)) == .stale)
    }
    @Test("a new complete CLI sample does not retain removed model pools")
    func removedPools() {
        let old = AccountUsageSnapshot(provider: .antigravity, planType: nil, primary: nil, secondary: nil,
            lifetimeTokens: nil, latestDailyTokens: nil, fetchedAt: .now,
            extraWindows: [.extra(key: "old", label: "Old pool", usedPercent: 99, windowDurationMinutes: 300, resetsAt: nil)])
        let next = AccountUsageSnapshot(provider: .antigravity, planType: nil, primary: nil, secondary: nil,
            lifetimeTokens: nil, latestDailyTokens: nil, fetchedAt: .now,
            extraWindows: [.extra(key: "current", label: "Current pool", usedPercent: 10, windowDurationMinutes: 300, resetsAt: nil)])
        #expect(next.preservingUnspecifiedExtras(from: old).displayWindows.map(\.id) == ["current"])
    }

    @Test("official current-account read", .enabled(if: ProcessInfo.processInfo.environment["VIBEBUDDY_ANTIGRAVITY_USAGE_LIVE"] == "1"))
    func liveCommand() async throws {
        let sample = try await AntigravityUsageProvider().fetch()
        #expect(sample.provider == .antigravity)
        #expect(!sample.displayWindows.isEmpty)
        #expect(sample.displayWindows.allSatisfy { $0.poolKey != nil && $0.resetsAt != nil })
        print("Antigravity live allowance: \(sample.displayWindows.count) windows, \(sample.independentPools.count) model pools")
    }

}
