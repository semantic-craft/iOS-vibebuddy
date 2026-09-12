import Testing
import Foundation
@testable import VibeBuddyKit

/// The reminder schedule for followed completions: a backing-off cadence
/// (5, 10, 20, 40 minutes), four at most, and silence the moment the
/// completion is read or replaced.
@Suite("CompletionReminderSchedule")
struct CompletionReminderTests {

    private func session(_ id: String = "s", _ status: SessionStatus = .done,
                         attention: SessionAttention? = .followed, unread: Bool = true,
                         since: TimeInterval = 0, probeRetired: Bool? = nil) -> AgentSession {
        AgentSession(id: id, agent: .claudeCode, project: id, status: status,
                     hasUnreadCompletion: unread, probeRetired: probeRetired, attention: attention,
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

    @Test("the first reminder comes five minutes after the completion, then the gaps double")
    func cadence() {
        var s = CompletionReminderSchedule()
        let done = session(since: 0)
        #expect(remind(&s, [done], now: at(1)).isEmpty)
        #expect(remind(&s, [done], now: at(299)).isEmpty)
        #expect(remind(&s, [done], now: at(300)) == ["s"])          // +5 min
        #expect(remind(&s, [done], now: at(301)).isEmpty)
        #expect(remind(&s, [done], now: at(600)).isEmpty)           // a fixed 5 would fire here
        #expect(remind(&s, [done], now: at(899)).isEmpty)
        #expect(remind(&s, [done], now: at(900)) == ["s"])          // +10 min
        #expect(remind(&s, [done], now: at(2099)).isEmpty)
        #expect(remind(&s, [done], now: at(2100)) == ["s"])         // +20 min
        #expect(remind(&s, [done], now: at(4499)).isEmpty)
        #expect(remind(&s, [done], now: at(4500)) == ["s"])         // +40 min, the last
        #expect(remind(&s, [done], now: at(9000)).isEmpty)
        #expect(s.remindersSent(for: "s") == 4)
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
        #expect(s.due([done], now: at(602)).isEmpty)            // the second gap is ten minutes
        #expect(s.due([done], now: at(902)).map(\.id) == ["s"])
        #expect(s.remindersSent(for: "s") == 1)
    }

    @Test("a skipped proposal waits one interval before it is offered again, and spends no slot")
    func skippedProposalWaitsAnInterval() {
        var s = CompletionReminderSchedule()
        let done = session(since: 0)
        #expect(s.due([done], now: at(300)).map(\.id) == ["s"])
        s.markSkipped("s", now: at(300))                     // nobody could take it
        #expect(s.due([done], now: at(330)).isEmpty)           // not on the next 30 s pass
        #expect(s.due([done], now: at(600)).map(\.id) == ["s"])  // but the same interval later
        #expect(s.remindersSent(for: "s") == 0)
    }

    @Test("a completion first seen long after it happened is reminded about right away")
    func lateFirstSight() {
        var s = CompletionReminderSchedule()
        #expect(s.due([session(since: 0)], now: at(1200)).map(\.id) == ["s"])
    }

    @Test("four reminders at most, spread over 75 minutes, then silence for that completion")
    func cap() {
        var s = CompletionReminderSchedule()
        let done = session(since: 0)
        var minutes: [Int] = []
        for minute in stride(from: 1, through: 240, by: 1) where !remind(&s, [done], now: at(TimeInterval(minute * 60))).isEmpty {
            minutes.append(minute)
        }
        #expect(minutes == [5, 15, 35, 75])
        #expect(minutes.count == CompletionReminderSchedule.maxReminders)
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
            session("normal", attention: .normal),
            session("muted", attention: .muted),
            session("legacy", attention: nil),
            session("working", .working),
            session("waiting", .needsResponse),
            session("read", unread: false),
            session("retired", probeRetired: true),
        ]
        _ = s.due(candidates, now: at(0))
        #expect(s.due(candidates, now: at(3600)).isEmpty)
    }
}
