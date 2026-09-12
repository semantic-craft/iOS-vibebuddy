import Foundation
import VibeBuddyKit

/// Mac menu projection: the snapshot cut into the Companion's three attention
/// groups (`StateGroups`, the Kit's own rule), each ordered by
/// when something last happened. The view consumes this and does no sorting,
/// grouping or filtering of its own.
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

    /// One collapsible group of the panel's list. The kind is the identity, not
    /// the heading: a group keeps the state the user collapsed it into across
    /// snapshots, and across a change of language.
    public struct Section: Identifiable, Equatable, Sendable {
        public enum Kind: String, Sendable { case needsYou, working, done }
        public let kind: Kind
        public let sessions: [AgentSession]
        public var id: String { kind.rawValue }
    }

    /// The non-empty groups in attention order — `needsYou`, `working`, `done` —
    /// newest first inside each. An empty group is absent, not empty, so the
    /// panel shortens instead of showing a heading over nothing.
    public let sections: [Section]
    /// Always the whole snapshot. Typing narrows the list; it must not change
    /// what the panel says is going on.
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

        let groups = StateGroups(ordered)
        sections = [Section(kind: .needsYou, sessions: groups.needsYou),
                    Section(kind: .working, sessions: groups.working),
                    Section(kind: .done, sessions: groups.done)]
            .filter { !$0.sessions.isEmpty }

        if sessions.isEmpty {
            emptyState = .noSessions
        } else if matched.isEmpty {
            emptyState = .noMatches(trimmed)
        } else {
            emptyState = nil
        }
    }

    /// Every matched row in the order the panel draws them.
    public var rows: [AgentSession] { sections.flatMap(\.sessions) }

    /// The sessions in one group, empty when the group is absent.
    public func sessions(_ kind: Section.Kind) -> [AgentSession] {
        sections.first { $0.kind == kind }?.sessions ?? []
    }

    /// The row Return jumps to: the most urgent one when something is waiting,
    /// otherwise the newest of whatever group leads the list.
    public var topResult: AgentSession? { sections.first?.sessions.first }

    /// Matches what the row actually shows — its title and the agent's own
    /// summary — plus the project behind a named session, so searching by
    /// project still finds one that displays a name instead.
    private static func matches(_ session: AgentSession, _ query: String) -> Bool {
        [session.displayTitle, session.project, session.summary ?? ""]
            .contains { $0.range(of: query, options: .caseInsensitive) != nil }
    }

    /// The list's time column: `now`, `44s`, `12m`, `3h`, `2d`. Deliberately
    /// terse — it rides at the end of a row whose own words are the point.
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
