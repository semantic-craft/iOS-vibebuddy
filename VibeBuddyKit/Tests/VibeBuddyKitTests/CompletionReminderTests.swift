import Testing
import Foundation
@testable import VibeBuddyKit

/// The reminder schedule for followed completions: five-minute cadence, an
/// hour's cap, and silence the moment the completion is read or replaced.
@Suite("CompletionReminderSchedule")
struct CompletionReminderTests {

    private func session(_ id: String = "s", _ status: SessionStatus = .done,
                         followed: Bool? = true, unread: Bool = true,
                         since: TimeInterval = 0, probeRetired: Bool? = nil) -> AgentSession {
        AgentSession(id: id, agent: .claudeCode, project: id, status: status,
                     hasUnreadCompletion: unread, probeRetired: probeRetired, followed: followed,
                     statusSince: Date(timeIntervalSince1970: since),
                     updatedAt: Date(timeIntervalSince1970: since))
    }

    private func at(_ t: TimeInterval) -> Date { Date(timeIntervalSince1970: t) }

    /// Propose, deliver, count — the way the Mac's ticker drives it.
    private func remind(_ s: inout CompletionReminderSchedule, _ sessions: [AgentSession],
                        now: Date) -> [String] {
        let due = s.due(sessions, now: now)
        for session in due { s.markReminded(session.id, now: now) }
        return due.map(\.id)
    }

    @Test("the first reminder comes one interval after the completion, then every interval")
    func cadence() {
        var s = CompletionReminderSchedule()
        let done = session(since: 0)
        #expect(remind(&s, [done], now: at(1)).isEmpty)
        #expect(remind(&s, [done], now: at(299)).isEmpty)
        #expect(remind(&s, [done], now: at(300)) == ["s"])
        #expect(remind(&s, [done], now: at(301)).isEmpty)
        #expect(remind(&s, [done], now: at(599)).isEmpty)
        #expect(remind(&s, [done], now: at(600)) == ["s"])
        #expect(s.remindersSent(for: "s") == 2)
    }

    @Test("a reminder nobody could deliver spends no slot and is offered again")
    func suppressedDeliveryKeepsTheSlot() {
        var s = CompletionReminderSchedule()
        let done = session(since: 0)
        // Due, but every channel was silent (Focus mode, no phone): not marked.
        #expect(s.due([done], now: at(300)).map(\.id) == ["s"])
        #expect(s.remindersSent(for: "s") == 0)
        // Still owed on the very next pass, and the count only moves on delivery.
        #expect(s.due([done], now: at(302)).map(\.id) == ["s"])
        s.markReminded("s", now: at(302))
        #expect(s.due([done], now: at(500)).isEmpty)
        #expect(s.due([done], now: at(602)).map(\.id) == ["s"])
        #expect(s.remindersSent(for: "s") == 1)
    }

    @Test("a completion first seen long after it happened is reminded about right away")
    func lateFirstSight() {
        var s = CompletionReminderSchedule()
        #expect(s.due([session(since: 0)], now: at(1200)).map(\.id) == ["s"])
    }

    @Test("twelve reminders at most, then silence for that completion")
    func cap() {
        var s = CompletionReminderSchedule()
        let done = session(since: 0)
        var count = 0
        for minute in stride(from: 5, through: 120, by: 5) {
            count += remind(&s, [done], now: at(TimeInterval(minute * 60))).count
        }
        #expect(count == CompletionReminderSchedule.maxReminders)
    }

    @Test("reading the completion stops the reminders; a new completion starts over")
    func stopsOnReadAndResets() {
        var s = CompletionReminderSchedule()
        _ = remind(&s, [session(since: 0)], now: at(0))
        #expect(remind(&s, [session(since: 0)], now: at(300)).count == 1)
        // Read on any device: unread bit cleared through the Mac.
        #expect(remind(&s, [session(unread: false, since: 0)], now: at(600)).isEmpty)
        #expect(s.remindersSent(for: "s") == 0)
        // Later the same session finishes another turn: fresh statusSince, fresh count.
        _ = remind(&s, [session(since: 1000)], now: at(1000))
        #expect(remind(&s, [session(since: 1000)], now: at(1300)).count == 1)
        #expect(s.remindersSent(for: "s") == 1)
    }

    @Test("only followed, done, unread, non-retired sessions are ever due")
    func eligibility() {
        var s = CompletionReminderSchedule()
        let candidates = [
            session("unfollowed", followed: false),
            session("legacy", followed: nil),
            session("working", .working),
            session("waiting", .needsResponse),
            session("read", unread: false),
            session("retired", probeRetired: true),
        ]
        _ = s.due(candidates, now: at(0))
        #expect(s.due(candidates, now: at(3600)).isEmpty)
    }
}
