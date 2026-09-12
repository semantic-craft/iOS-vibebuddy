import Foundation

/// Which sessions count as *current* on a summary line — the one rule every
/// surface reads, so the phone, the Mac panel, the Watch and the Live Activity
/// never disagree about whether anything is going on (ADR-0017).
///
/// The Mac keeps a session for as long as its process lived, so a `done` task
/// from last week still arrives in every snapshot. A summary that counted it
/// would say "7 done" forever; a list that showed it would bury today's work.
/// So a finished session ages out after a day — unless something about it
/// still wants a person:
///
/// - it is waiting (`needsResponse`), whatever its age;
/// - it failed, because a failure that nobody has looked at is not history;
/// - it is still `working`: a stalled run is a run, and hiding it would make
///   every other surface's "working" count a lie;
/// - it is followed and its completion is unread: the Mac is still reminding
///   about it every five minutes (`CompletionReminderSchedule`), so the phone
///   must still show what the reminder is about.
///
/// The window is presentation only. Notifications, deep links, acknowledgements
/// and the buddy's scope keep resolving against the complete session set.
public enum SessionCurrency {
    /// A day. Long enough to still find last night's run over breakfast.
    public static let window: TimeInterval = 24 * 60 * 60

    public static func isCurrent(_ session: AgentSession, now: Date,
                                 window: TimeInterval = window) -> Bool {
        switch session.status {
        case .needsResponse, .working: return true
        case .done: break
        }
        if session.isStuck { return true }
        if session.hasUnreadCompletion && session.effectiveAttention == .followed { return true }
        return now.timeIntervalSince(session.updatedAt) <= window
    }

    /// The current sessions, in the order they arrived.
    public static func current(_ sessions: [AgentSession], now: Date,
                               window: TimeInterval = window) -> [AgentSession] {
        sessions.filter { isCurrent($0, now: now, window: window) }
    }

    /// The rest — what a list folds into "Older" or offers back with
    /// "Show N older".
    public static func older(_ sessions: [AgentSession], now: Date,
                             window: TimeInterval = window) -> [AgentSession] {
        sessions.filter { !isCurrent($0, now: now, window: window) }
    }
}
