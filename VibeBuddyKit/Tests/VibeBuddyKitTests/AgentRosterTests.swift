import Foundation
import Testing
@testable import VibeBuddyKit

@Suite("Agent roster and quota readings")
struct AgentRosterTests {
    private func session(_ id: String, _ agent: AgentKind, _ status: SessionStatus,
                         at time: TimeInterval = 90, unread: Bool = false) -> AgentSession {
        AgentSession(id: id, agent: agent, project: "Alpha", status: status,
                     waitKind: status == .needsResponse ? .question : nil,
                     hasUnreadCompletion: unread,
                     statusSince: Date(timeIntervalSince1970: time),
                     updatedAt: Date(timeIntervalSince1970: time))
    }

    private let now = Date(timeIntervalSince1970: 100)

    @Test func theRosterLeadsWithAllAgentsAndTalliesEachOne() {
        let input = [session("a", .claudeCode, .needsResponse),
                     session("b", .claudeCode, .working),
                     session("c", .claudeCode, .done, unread: true),
                     session("d", .codex, .working)]
        let items = AgentRoster.items(input, now: now)

        #expect(items.map(\.id) == ["all", "claudeCode", "codex"])
        #expect(items[0].tally == .init(total: 4, needsYou: 1, working: 2, unread: 1))
        #expect(items[1].tally == .init(total: 3, needsYou: 1, working: 1, unread: 1))
        #expect(items[2].tally == .init(total: 1, needsYou: 0, working: 1, unread: 0))
    }

    @Test func theChosenAgentStaysListedAfterItsLastSessionAgesOut() {
        let input = [session("d", .codex, .working)]
        #expect(AgentRoster.items(input, now: now).map(\.id) == ["all", "codex"])
        let kept = AgentRoster.items(input, keeping: .grok, now: now)
        #expect(kept.map(\.id) == ["all", "codex", "grok"])
        // Listed with nothing under it, never with a borrowed count.
        #expect(kept.last?.tally == .init())
    }

    @Test func aQuotaReadingIsTheWindowClosestToRunningOut() {
        let quota = ProviderQuota(provider: .claude, weeklyRemainingPercent: 42,
                                  weeklyResetsAt: Date(timeIntervalSince1970: 900),
                                  shortWindowRemainingPercent: 8)
        let reading = quota.tightest
        #expect(reading?.remainingPercent == 8)
        #expect(reading?.usedPercent == 92)
    }

    @Test func scopedWindowsNeverStandInForThePoolAndAbsenceIsNotZero() {
        let scoped = ProviderQuota(provider: .claude, scopedWindows: [
            QuotaWindow(remainingPercent: 3, durationMinutes: 10_080, resetsAt: nil, observedAt: now)
        ])
        #expect(scoped.tightest == nil)
        #expect(ProviderQuota(provider: .codex).tightest == nil)
    }

    @Test func aFleetReadsItsTightestProviderAndAnAgentReadsItsOwn() {
        let quotas = [ProviderQuota(provider: .claude, weeklyRemainingPercent: 60),
                      ProviderQuota(provider: .grokBot, weeklyRemainingPercent: 5)]
        #expect(quotas.tightestReading?.remainingPercent == 5)
        #expect(quotas.reading(for: .claudeCode)?.remainingPercent == 60)
        #expect(quotas.reading(for: .grokBot)?.remainingPercent == 5)
        // An agent with no account of its own has no ring to draw.
        #expect(quotas.reading(for: .copilot) == nil)
    }
}
