import Foundation
import Testing
@testable import VibeBuddyKit

@Suite("ProviderQuota wire forward-compat (#111)")
struct ProviderQuotaWireCompatTests {

    @Test("unknown provider string in providerQuota does not kill Snapshot decode")
    func unknownProviderSkipped() throws {
        let json = """
        {"sessions":[],"serverTime":1700000000,
         "providerQuota":[
           {"provider":"codex","weeklyRemainingPercent":70},
           {"provider":"futureProvider","weeklyRemainingPercent":12},
           {"provider":"claude","weeklyRemainingPercent":40}
         ]}
        """.data(using: .utf8)!
        let snap = try JSONDecoder().decode(Snapshot.self, from: json)
        #expect(snap.providerQuota?.map(\.provider) == [.codex, .claude])
        #expect(snap.sessions.isEmpty)
    }

    @Test("credits and spend round-trip and stay optional on old payloads")
    func creditsAndSpendAreAdditive() throws {
        let json = """
        {"sessions":[],"serverTime":1700000000,
         "providerQuota":[{"provider":"codex","weeklyRemainingPercent":70}]}
        """.data(using: .utf8)!
        let snap = try JSONDecoder().decode(Snapshot.self, from: json)
        #expect(snap.providerQuota?.first?.credits == nil)
        #expect(snap.providerQuota?.first?.spend == nil)

        var row = ProviderQuota(provider: .codex, weeklyRemainingPercent: 70)
        row.credits = QuotaCredits(remaining: 12.5, label: "Credits")
        row.spend = [QuotaSpend(label: "Extra usage", amount: 4.2)]
        let encoded = try JSONDecoder().decode(
            Snapshot.self,
            from: JSONEncoder().encode(Snapshot(
                sessions: [], serverTime: Date(timeIntervalSince1970: 1_700_000_000),
                sourceID: "mac-1", providerQuota: [row]))
        )
        #expect(encoded.providerQuota?.first?.credits?.remaining == 12.5)
        #expect(encoded.providerQuota?.first?.spend?.first?.amount == 4.2)
    }

    @Test("ServerEvent.snapshot round-trip keeps known rows after unknown skip")
    func serverEventSurvivesUnknownProvider() throws {
        let snapJSON = """
        {"sessions":[],"serverTime":1700000000,
         "providerQuota":[
           {"provider":"codex","weeklyRemainingPercent":10},
           {"provider":"brandNewProvider","unavailableReason":"x"}
         ]}
        """.data(using: .utf8)!
        let snap = try JSONDecoder().decode(Snapshot.self, from: snapJSON)
        #expect(snap.providerQuota?.map(\.provider) == [.codex])
        let event = ServerEvent.snapshot(snap)
        let back = try JSONDecoder().decode(ServerEvent.self, from: JSONEncoder().encode(event))
        #expect(back == event)
    }
}

@Suite("Grok Bot paired quota")
struct GrokBotPairedQuotaTests {
    @Test("Snapshot and Watch relay preserve Grok Bot separately from Grok Build")
    func quotaAcrossDevices() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let reset = now.addingTimeInterval(3600)
        let rows = [
            ProviderQuota(provider: .grok, weeklyRemainingPercent: 60, observedAt: now),
            ProviderQuota(provider: .grokBot, accountLabel: "Account masked",
                weeklyRemainingPercent: 89, weeklyResetsAt: reset,
                weeklyWindowDurationMinutes: 10_080, observedAt: now)
        ]
        let source = Snapshot(sessions: [], serverTime: now, sourceID: "mac-test", providerQuota: rows)
        let phone = try JSONDecoder().decode(Snapshot.self, from: JSONEncoder().encode(source))
        #expect(phone.providerQuota == rows)
        let watch = WatchDashboardProjection.make(snapshot: phone,
            quotas: phone.providerQuota ?? [], relay: .live, now: now)
        let received = try JSONDecoder().decode(WatchDashboardState.self, from: JSONEncoder().encode(watch))
        let bot = try #require(received.quota(.grokBot))
        #expect(bot.accountLabel == "Account masked")
        #expect(bot.weeklyRemainingPercent == 89)
        #expect(bot.weeklyResetsAt == reset)
        #expect(bot.observedAt == now)
        #expect(received.quota(.grok)?.weeklyRemainingPercent == 60)
        #expect(bot.window(.weekly).status(now: reset) == .awaitingReset)
        #expect(bot.window(.weekly).currentRemainingPercent(now: reset) == nil)
    }
}
