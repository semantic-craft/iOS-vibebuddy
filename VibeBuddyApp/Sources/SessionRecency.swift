import Foundation
import VibeBuddyKit

/// How long a quiet session stays on the phone's dashboard.
///
/// The Mac keeps a session as long as its process lived, so a `done` task from
/// last week still arrives in every snapshot. On the phone that buries today's
/// work under days of finished rows, so the list shows only what moved inside
/// the window — with one exception: a session that **needs a person** never ages
/// out, because surfacing exactly those is why the phone exists.
enum SessionRecency {
    /// A day. Long enough to still find last night's run over breakfast.
    static let window: TimeInterval = 24 * 60 * 60

    static func isCurrent(_ session: AgentSession, now: Date, window: TimeInterval = window) -> Bool {
        if session.status == .needsResponse { return true }
        return now.timeIntervalSince(session.updatedAt) <= window
    }

    static func current(_ sessions: [AgentSession], now: Date, window: TimeInterval = window) -> [AgentSession] {
        sessions.filter { isCurrent($0, now: now, window: window) }
    }

    /// How many rows the window is holding back, so the list can offer them.
    static func inactiveCount(_ sessions: [AgentSession], now: Date, window: TimeInterval = window) -> Int {
        sessions.filter { !isCurrent($0, now: now, window: window) }.count
    }
}
