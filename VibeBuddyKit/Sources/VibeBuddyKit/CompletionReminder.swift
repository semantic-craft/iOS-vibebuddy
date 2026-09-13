import Foundation

/// When to say "still finished, still unread" again for a followed session —
/// one whose effective `SessionAttention` is `followed`, whether the user set
/// that by hand or the daemon inferred it from recent interaction.
///
/// A followed session that reaches `done` gets its one `agentDone` cue from
/// `SoundPolicy` like any other. This schedule adds the reminders behind it:
/// one after each of `intervals` — 5, 10, 20, then 40 minutes — for as long as
/// the completion stays unread, so the last one lands 75 minutes after the
/// completion and there are never more than four. Reading it on any device
/// clears `hasUnreadCompletion` through the Mac, so the next evaluation finds
/// nothing due and forgets the session. A new completion has a new
/// `statusSince`, which starts the count over.
///
/// The cadence backs off rather than repeating (ADR-0019): every reminder is
/// mirrored to the wrist as a fresh buzz, and a fixed five minutes for an hour
/// was twelve buzzes for one piece of finished work. Backing off keeps the
/// first reminder quick and the coverage over an hour while cutting the
/// interruptions to four.
///
/// Pure and clock-injected. `due` proposes; the caller posts and then calls
/// `markReminded` only when at least one channel actually took the cue. A
/// reminder that every channel suppressed (Focus mode, category off, no phone)
/// therefore does not spend one of the slots: the completion is still unread,
/// and the next eligible moment says so.
public struct CompletionReminderSchedule: Sendable, Equatable {
    /// The gap before each reminder, in order; the last one is not repeated.
    public static let intervals: [TimeInterval] = [5 * 60, 10 * 60, 20 * 60, 40 * 60]
    public static var maxReminders: Int { intervals.count }
    /// The first gap, kept for callers that only need "how soon at the earliest".
    public static var interval: TimeInterval { intervals[0] }

    /// How long to wait after `count` reminders have been sent before the next.
    public static func interval(afterReminders count: Int) -> TimeInterval {
        intervals[min(max(count, 0), intervals.count - 1)]
    }

    private struct Progress: Equatable {
        var completedAt: Date
        var count: Int
        var lastAt: Date
    }

    private var progress: [String: Progress] = [:]

    public init() {}

    /// The sessions owed a reminder right now. Nothing is counted here: call
    /// `markReminded` for each one that was actually delivered somewhere.
    public mutating func due(_ sessions: [AgentSession], now: Date) -> [AgentSession] {
        var due: [AgentSession] = []
        var eligible = Set<String>()
        for session in sessions where Self.isEligible(session) {
            eligible.insert(session.id)
            // First sight of a completion starts its clock. The completion itself
            // already rang (or was filtered); the first reminder is one interval
            // after it, which may be right now if we only just noticed it.
            let p = progress[session.id].flatMap { $0.completedAt == session.statusSince ? $0 : nil }
                ?? Progress(completedAt: session.statusSince, count: 0, lastAt: session.statusSince)
            progress[session.id] = p
            if p.count < Self.maxReminders,
               now.timeIntervalSince(p.lastAt) >= Self.interval(afterReminders: p.count) {
                due.append(session)
            }
        }
        // Read, unfollowed, working again, or gone: nothing left to remind about.
        progress = progress.filter { eligible.contains($0.key) }
        return due
    }

    /// A reminder for this session was handed to at least one channel: spend a
    /// slot and start the next interval from now.
    public mutating func markReminded(_ sessionID: String, now: Date) {
        guard var p = progress[sessionID] else { return }
        p.count += 1
        p.lastAt = now
        progress[sessionID] = p
    }

    /// Nobody could take the reminder: wait the current interval before
    /// proposing it again, without spending a slot. Keeps an undeliverable
    /// completion from being re-proposed — and re-logged as skipped — on every
    /// service pass.
    public mutating func markSkipped(_ sessionID: String, now: Date) {
        guard var p = progress[sessionID] else { return }
        p.lastAt = now
        progress[sessionID] = p
    }

    /// How many reminders this session's current completion has had.
    public func remindersSent(for sessionID: String) -> Int {
        progress[sessionID]?.count ?? 0
    }

    private static func isEligible(_ session: AgentSession) -> Bool {
        session.effectiveAttention == .followed && session.status == .done && session.hasUnreadCompletion
            && session.probeRetired != true
    }
}
