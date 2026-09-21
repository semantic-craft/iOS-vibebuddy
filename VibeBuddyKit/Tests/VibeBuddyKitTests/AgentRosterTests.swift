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

    @Test func aSmallScreenReadsTheLowestAllowanceFirstAndUnreadableOnesLast() {
        // A window with nothing observed reads as unavailable on the row, so
        // the order has to treat it that way too: real readings carry a time.
        let observed = now.addingTimeInterval(-60)
        let quotas = [ProviderQuota(provider: .claude, weeklyRemainingPercent: 60, observedAt: observed),
                      ProviderQuota(provider: .cursor),
                      ProviderQuota(provider: .grokBot, weeklyRemainingPercent: 4, observedAt: observed),
                      ProviderQuota(provider: .codex, weeklyRemainingPercent: 60, observedAt: observed)]
        #expect(quotas.displayedLowestFirst(now: now).map(\.provider) == [.grokBot, .claude, .codex, .cursor],
                "ties settle by name so the strip never reshuffles under the eye")
    }

    /// The Watch reads the weekly pool and files the row by that same number:
    /// a Cursor row showing 74% must not sort above one showing 41% just
    /// because an inner window is lower.
    @Test func theOrderFollowsTheNumberEachRowShows() {
        let observed = now.addingTimeInterval(-60)
        let cursor = ProviderQuota(provider: .cursor, otherWindows: [
            QuotaWindow(remainingPercent: 74, durationMinutes: 43_200, resetsAt: nil, observedAt: observed, label: "Cursor Models"),
            QuotaWindow(remainingPercent: 31, durationMinutes: 43_200, resetsAt: nil, observedAt: observed, label: "Other Models")
        ], observedAt: observed)
        let claude = ProviderQuota(provider: .claude, weeklyRemainingPercent: 41,
                                   weeklyWindowDurationMinutes: 10_080, observedAt: observed)

        #expect(cursor.tightest?.remainingPercent == 31, "the pool itself is still read honestly")
        #expect([cursor, claude].displayedLowestFirst(now: now).map(\.provider) == [.claude, .cursor])
    }

    @Test func onlyAnAllowanceThatChangesTheNextMoveCountsAsLow() {
        #expect(QuotaReading(remainingPercent: 4).isLow)
        #expect(QuotaReading(remainingPercent: 10).isLow)
        #expect(!QuotaReading(remainingPercent: 11).isLow)
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
