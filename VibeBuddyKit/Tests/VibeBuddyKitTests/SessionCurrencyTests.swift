import Foundation
import Testing
@testable import VibeBuddyKit

@Suite("Session currency — which sessions a summary line counts")
struct SessionCurrencyTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func session(_ id: String, _ status: SessionStatus, hoursAgo: Double,
                         failed: Bool = false, unread: Bool = false,
                         attention: SessionAttention? = nil) -> AgentSession {
        let at = now.addingTimeInterval(-hoursAgo * 3600)
        var s = AgentSession(id: id, agent: .claudeCode, project: "p", status: status,
                             failed: failed, hasUnreadCompletion: unread,
                             statusSince: at, updatedAt: at)
        s.attention = attention
        return s
    }

    @Test func finishedWorkAgesOutAfterADay() {
        #expect(SessionCurrency.isCurrent(session("fresh", .done, hoursAgo: 2), now: now))
        #expect(SessionCurrency.isCurrent(session("edge", .done, hoursAgo: 23.9), now: now))
        #expect(!SessionCurrency.isCurrent(session("past", .done, hoursAgo: 24.1), now: now))
        #expect(!SessionCurrency.isCurrent(session("old", .done, hoursAgo: 5 * 24), now: now))
    }

    @Test func historicalFailuresAgeOut() {
        var row = session("history-failure", .done, hoursAgo: 48, failed: true)
        row.historyOnly = true
        #expect(!SessionCurrency.isCurrent(row, now: now))
        #expect(SessionCurrency.older([row], now: now).map(\.id) == [row.id])
    }

    @Test func aWaitAFailureAndARunNeverAgeOut() {
        #expect(SessionCurrency.isCurrent(session("wait", .needsResponse, hoursAgo: 5 * 24), now: now))
        #expect(SessionCurrency.isCurrent(session("broke", .done, hoursAgo: 5 * 24, failed: true), now: now))
        #expect(SessionCurrency.isCurrent(session("stalled", .working, hoursAgo: 5 * 24), now: now))
    }

    @Test func legacyUnreadDoesNotKeepOldCompletionsCurrent() {
        // Legacy reading flags and attention do not extend the 24-hour current window.
        #expect(!SessionCurrency.isCurrent(session("followed", .done, hoursAgo: 30, unread: true,
                                                  attention: .followed), now: now))
        #expect(!SessionCurrency.isCurrent(session("normal", .done, hoursAgo: 30, unread: true), now: now))
        #expect(!SessionCurrency.isCurrent(session("muted", .done, hoursAgo: 30, unread: true,
                                                   attention: .muted), now: now))
        #expect(SessionCurrency.isCurrent(session("fresh", .done, hoursAgo: 3, unread: true), now: now))
        // Followed completions use the same age cutoff.
        #expect(!SessionCurrency.isCurrent(session("seen", .done, hoursAgo: 30, attention: .followed), now: now))
    }

    @Test func currentAndOlderPartitionTheInputInOrder() {
        let input = [session("a", .done, hoursAgo: 1), session("b", .done, hoursAgo: 48),
                     session("c", .needsResponse, hoursAgo: 48), session("d", .done, hoursAgo: 30)]
        #expect(SessionCurrency.current(input, now: now).map(\.id) == ["a", "c"])
        #expect(SessionCurrency.older(input, now: now).map(\.id) == ["b", "d"])
    }

    @Test func aSummaryOverCurrentSessionsDropsTheOldOnes() {
        let input = [session("a", .done, hoursAgo: 1, unread: true), session("b", .done, hoursAgo: 48),
                     session("c", .done, hoursAgo: 48), session("d", .working, hoursAgo: 1)]
        let whole = TaskPresentationSummary(sessions: input)
        let current = TaskPresentationSummary(currentIn: input, now: now)
        #expect(whole.completeUnread == 3)
        #expect(current.idle == 0)
        #expect(current.completeUnread == 1)
        #expect(current.thinking == 1)
        #expect(current.total == 2)
    }

    @Test func theWidgetSnapshotLeadsWithACurrentSession() {
        // Old completions are outside the current window and cannot lead the widget.
        let input = [session("old", .done, hoursAgo: 48, unread: true), session("run", .working, hoursAgo: 1)]
        let snapshot = TaskPresentationSnapshot(sessions: input, updatedAt: now)
        #expect(snapshot.topSessionId == "run")
        #expect(snapshot.summary.completeUnread == 0)
    }
}
