import Foundation

/// When to say "still finished, still unread" again for a followed session.
///
/// A followed session that reaches `done` gets its one `agentDone` cue from
/// `SoundPolicy` like any other. This schedule adds the reminders behind it:
/// every `interval` after the completion, at most `maxReminders` times, for as
/// long as the completion stays unread. Reading it on any device clears
/// `hasUnreadCompletion` through the Mac, so the next evaluation finds nothing
/// due and forgets the session. A new completion has a new `statusSince`, which
/// starts the count over.
///
/// Pure and clock-injected: the Mac's poll loop feeds it the current snapshot
/// and posts whatever comes back.
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

    /// The sessions owed a reminder right now. Calling this records them as
    /// reminded, so the next call within `interval` returns nothing for them.
    public mutating func due(_ sessions: [AgentSession], now: Date) -> [AgentSession] {
        var due: [AgentSession] = []
        var eligible = Set<String>()
        for session in sessions where Self.isEligible(session) {
            eligible.insert(session.id)
            // First sight of a completion starts its count. The completion itself
            // already rang (or was filtered); the first reminder is one interval
            // after it, which may be right now if we only just noticed it.
            var p = progress[session.id].flatMap { $0.completedAt == session.statusSince ? $0 : nil }
                ?? Progress(completedAt: session.statusSince, count: 0, lastAt: session.statusSince)
            if p.count < Self.maxReminders, now.timeIntervalSince(p.lastAt) >= Self.interval {
                p.count += 1
                p.lastAt = now
                due.append(session)
            }
            progress[session.id] = p
        }
        // Read, unfollowed, working again, or gone: nothing left to remind about.
        progress = progress.filter { eligible.contains($0.key) }
        return due
    }

    /// How many reminders this session's current completion has had.
    public func remindersSent(for sessionID: String) -> Int {
        progress[sessionID]?.count ?? 0
    }

    private static func isEligible(_ session: AgentSession) -> Bool {
        session.isFollowed && session.status == .done && session.hasUnreadCompletion
            && session.probeRetired != true
    }
}
