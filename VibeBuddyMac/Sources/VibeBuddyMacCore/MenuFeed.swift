import Foundation
import VibeBuddyKit

/// Mac menu projection: one feed ordered by when something last happened, with
/// the sessions that need a person pinned above it. The view consumes this and
/// does no sorting, grouping or filtering of its own.
///
/// Narrowing is the search field's job and nothing else's — there is no state
/// or agent filter, and no locally cleared round.
public struct MenuFeed: Sendable {
    public enum EmptyState: Equatable, Sendable {
        /// Nothing is reporting at all.
        case noSessions
        /// Sessions exist, but none match this query.
        case noMatches(String)
    }

    /// `.error` and `.requiresInput`, newest first. Disjoint from `feed`.
    public let pinned: [AgentSession]
    /// Everything else that matched, newest first.
    public let feed: [AgentSession]
    /// Always the whole snapshot. Typing narrows the list; it must not change
    /// what the panel says is going on, nor the dot on the pet's head.
    public let summary: TaskPresentationSummary
    /// How many sessions the query matched, and how many there are in total.
    public let matchCount: Int
    public let totalCount: Int
    /// The query with surrounding whitespace removed; empty when not searching.
    public let query: String
    public let emptyState: EmptyState?

    public init(_ sessions: [AgentSession], query: String = "") {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        self.query = trimmed
        summary = TaskPresentationSummary(sessions: sessions)
        totalCount = sessions.count

        let matched = trimmed.isEmpty ? sessions : sessions.filter { Self.matches($0, trimmed) }
        matchCount = matched.count

        // The order has to be total: sessions that share a timestamp keep the
        // snapshot's own order, so two identical rounds cannot reshuffle rows.
        let ordered = matched.enumerated().sorted {
            $0.element.updatedAt == $1.element.updatedAt
                ? $0.offset < $1.offset
                : $0.element.updatedAt > $1.element.updatedAt
        }.map(\.element)

        pinned = ordered.filter(Self.needsYou)
        feed = ordered.filter { !Self.needsYou($0) }

        if sessions.isEmpty {
            emptyState = .noSessions
        } else if matched.isEmpty {
            emptyState = .noMatches(trimmed)
        } else {
            emptyState = nil
        }
    }

    /// The row Return jumps to: the most urgent one when something is waiting,
    /// otherwise the newest.
    public var topResult: AgentSession? { pinned.first ?? feed.first }

    private static func needsYou(_ session: AgentSession) -> Bool {
        session.presentationState == .error || session.presentationState == .requiresInput
    }

    /// Matches what the row actually shows — its title and the agent's own
    /// summary — plus the project behind a named session, so searching by
    /// project still finds one that displays a name instead.
    private static func matches(_ session: AgentSession, _ query: String) -> Bool {
        [session.displayTitle, session.project, session.summary ?? ""]
            .contains { $0.range(of: query, options: .caseInsensitive) != nil }
    }

    /// The feed's time column: `now`, `44s`, `12m`, `3h`, `2d`. Deliberately
    /// terse — the column is 52pt and the row's own words are the point.
    public static func age(of date: Date, now: Date = Date()) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        switch seconds {
        case ..<5: return "now"
        case ..<60: return "\(seconds)s"
        case ..<3600: return "\(seconds / 60)m"
        case ..<86_400: return "\(seconds / 3600)h"
        default: return "\(seconds / 86_400)d"
        }
    }
}
