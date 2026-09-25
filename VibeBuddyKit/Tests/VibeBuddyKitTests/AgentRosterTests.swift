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
                                  weeklyResetsAt: now.addingTimeInterval(900),
                                  shortWindowRemainingPercent: 8, observedAt: now)
        let reading = quota.tightest(now: now)
        #expect(reading?.remainingPercent == 8)
        #expect(reading?.usedPercent == 92)
    }

    @Test func scopedWindowsNeverStandInForThePoolAndAbsenceIsNotZero() {
        let scoped = ProviderQuota(provider: .claude, scopedWindows: [
            QuotaWindow(remainingPercent: 3, durationMinutes: 10_080, resetsAt: nil, observedAt: now)
        ])
        #expect(scoped.tightest(now: now) == nil)
        #expect(ProviderQuota(provider: .codex).tightest(now: now) == nil)
    }

    @Test func aSmallScreenReadsTheLowestAllowanceFirstAndUnreadableOnesLast() {
        // A window with nothing observed reads as unavailable on the row, so
        // the order has to treat it that way too: real readings carry a time.
        let observed = now.addingTimeInterval(-60)
        let quotas = [ProviderQuota(provider: .claude, weeklyRemainingPercent: 60, observedAt: observed),
                      ProviderQuota(provider: .cursor),
                      ProviderQuota(provider: .grokBot, weeklyRemainingPercent: 4, observedAt: observed),
                      ProviderQuota(provider: .codex, weeklyRemainingPercent: 60, observedAt: observed)]
        #expect(quotas.stripRowsLowestFirst(now: now).map { $0.quota.provider } == [.grokBot, .claude, .codex, .cursor],
                "ties settle by name so the strip never reshuffles under the eye")
    }

    /// Cursor runs two pools over one billing period and either can stop work
    /// on its own, so a strip with room draws both — tightest first — and a
    /// surface with room for one draws the tightest.
    @Test func bothCursorPoolsAreShownAndOneRowMeansTheTightest() {
        let observed = now.addingTimeInterval(-60)
        let cursor = ProviderQuota(provider: .cursor, otherWindows: [
            QuotaWindow(remainingPercent: 74, durationMinutes: 43_200, resetsAt: nil, observedAt: observed, label: "Cursor Models"),
            QuotaWindow(remainingPercent: 31, durationMinutes: 43_200, resetsAt: nil, observedAt: observed, label: "Other Models")
        ], observedAt: observed)

        #expect(cursor.tightest(now: now)?.remainingPercent == 31, "the pool itself is still read honestly")
        #expect(cursor.poolReadings(now: now).map(\.label) == ["Other Models", "Cursor Models"])
        #expect(cursor.stripWindows(now: now).map(\.remainingPercent) == [31, 74],
                "a strip lists every pool, so the spent one cannot hide behind the other")
        #expect(cursor.displayWindow(now: now).remainingPercent == 31,
                "one row means the pool that decides whether the next turn goes through")
    }

    /// A pool pair is a pair whichever slot the projection filed it under. A
    /// seven-day Cursor cycle promotes one pool into the weekly slot; if that
    /// made the sibling invisible, the original bug would be back.
    @Test func aPairPromotedIntoTheWeeklySlotIsStillAPair() {
        let observed = now.addingTimeInterval(-60)
        let quota = ProviderQuota(provider: .cursor,
                                  weeklyRemainingPercent: 87, weeklyWindowDurationMinutes: 10_080,
                                  otherWindows: [QuotaWindow(remainingPercent: 0, durationMinutes: 10_080,
                                                             resetsAt: nil, observedAt: observed, label: "Other Models")],
                                  observedAt: observed)
        #expect(quota.stripWindows(now: now).map(\.remainingPercent) == [0, 87])
        #expect(quota.displayWindow(now: now).remainingPercent == 0)
    }

    /// A weekly pool beside a short one is one allowance read at two scales,
    /// so it keeps its single preferred row — while the ring still reads the
    /// short window, because a five-hour pool at 8% stops work too.
    @Test func aWeeklyAndShortPairStaysOneRow() {
        let observed = now.addingTimeInterval(-60)
        let codex = ProviderQuota(provider: .codex, weeklyRemainingPercent: 50,
                                  weeklyWindowDurationMinutes: 10_080,
                                  shortWindowRemainingPercent: 90,
                                  shortWindowDurationMinutes: 300, observedAt: observed)
        #expect(codex.stripWindows(now: now).map(\.remainingPercent) == [50])
        #expect(codex.tightest(now: now)?.remainingPercent == 50)
    }

    /// The strip is a flat list of rows, so a pool with room must not ride
    /// above another provider's tighter row just because its sibling is low.
    @Test func theStripOrdersRowsNotProviders() {
        let observed = now.addingTimeInterval(-60)
        let cursor = ProviderQuota(provider: .cursor, otherWindows: [
            QuotaWindow(remainingPercent: 90, durationMinutes: 43_200, resetsAt: nil, observedAt: observed, label: "Cursor Models"),
            QuotaWindow(remainingPercent: 10, durationMinutes: 43_200, resetsAt: nil, observedAt: observed, label: "Other Models")
        ], observedAt: observed)
        let claude = ProviderQuota(provider: .claude, weeklyRemainingPercent: 40,
                                   weeklyWindowDurationMinutes: 10_080, observedAt: observed)
        let rows = [cursor, claude].stripRowsLowestFirst(now: now)
        #expect(rows.map { $0.window.remainingPercent } == [10, 40, 90])
        #expect(Set(rows.map(\.id)).count == 3, "each pool keeps an identity of its own")
    }

    /// After the reset both pools stop reporting a percentage. A ring drawn
    /// from the stored number would keep showing the account as blocked after
    /// its allowance came back.
    @Test func aPoolThatHasResetReportsNothingRatherThanItsOldNumber() {
        let observed = now.addingTimeInterval(-3600)
        let reset = now.addingTimeInterval(-1)
        let cursor = ProviderQuota(provider: .cursor, otherWindows: [
            QuotaWindow(remainingPercent: 74, durationMinutes: 43_200, resetsAt: reset, observedAt: observed, label: "Cursor Models"),
            QuotaWindow(remainingPercent: 0, durationMinutes: 43_200, resetsAt: reset, observedAt: observed, label: "Other Models")
        ], observedAt: observed)
        #expect(cursor.poolReadings(now: now).isEmpty)
        #expect(cursor.tightest(now: now) == nil)
        #expect([cursor].tightestReading(now: now) == nil)
    }

    @Test func aFleetReadsItsTightestProviderAndAnAgentReadsItsOwn() {
        let quotas = [ProviderQuota(provider: .claude, weeklyRemainingPercent: 60, observedAt: now),
                      ProviderQuota(provider: .grokBot, weeklyRemainingPercent: 5, observedAt: now)]
        #expect(quotas.tightestReading(now: now)?.remainingPercent == 5)
        #expect(quotas.reading(for: .claudeCode, now: now)?.remainingPercent == 60)
        #expect(quotas.reading(for: .grokBot, now: now)?.remainingPercent == 5)
        // An agent with no account of its own has no ring to draw.
        #expect(quotas.reading(for: .copilot, now: now) == nil)
    }
}
