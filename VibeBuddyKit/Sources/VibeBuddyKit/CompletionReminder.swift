import Foundation

/// When to say "still finished, still unread" again for a followed session —
/// one whose effective `SessionAttention` is `followed`, whether the user set
/// that by hand or the daemon inferred it from recent interaction.
///
/// A followed session that reaches `done` gets its one `agentDone` cue from
/// `SoundPolicy` like any other. This schedule adds the reminders behind it:
/// every `interval` after the completion, at most `maxReminders` times, for as
/// long as the completion stays unread. Reading it on any device clears
/// `hasUnreadCompletion` through the Mac, so the next evaluation finds nothing
/// due and forgets the session. A new completion has a new `statusSince`, which
/// starts the count over.
///
/// Pure and clock-injected. `due` proposes; the caller posts and then calls
/// `markReminded` only when at least one channel actually took the cue. A
/// reminder that every channel suppressed (Focus mode, category off, no phone)
/// therefore does not spend one of the twelve slots: the completion is still
/// unread, and the next eligible moment says so.
public struct CompletionReminderSchedule: Sendable, Equatable {
    public static let interval: TimeInterval = 5 * 60
    public static let maxReminders = 12

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
            if p.count < Self.maxReminders, now.timeIntervalSince(p.lastAt) >= Self.interval {
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

    /// Nobody could take the reminder: wait one interval before proposing it
    /// again, without spending a slot. Keeps an undeliverable completion from
    /// being re-proposed — and re-logged as skipped — on every service pass.
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
