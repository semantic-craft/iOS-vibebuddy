import Foundation
import VibeBuddyKit

/// The agent rail's readings and the workspace column's session groups: the
/// dashboard's first axis is the agent, not the project, so both surfaces read
/// the same projection. Like `DashboardSessionList` it only projects — it never
/// mutates the shared snapshot and never chooses a selection.
public enum DashboardAgentColumn {
    /// What one rail entry has to say in a 48 pt column: how many sessions it
    /// owns and how they are split, so the tile can carry a count and an
    /// attention dot without the column re-reading the snapshot itself.
    public struct Tally: Sendable, Equatable {
        public let total: Int
        public let needsYou: Int
        public let working: Int
        public let unread: Int

        public init(total: Int = 0, needsYou: Int = 0, working: Int = 0, unread: Int = 0) {
            self.total = total
            self.needsYou = needsYou
            self.working = working
            self.unread = unread
        }
    }

    public struct Item: Identifiable, Sendable, Equatable {
        /// `nil` is the rail's "All agents" entry, which always leads.
        public let agent: AgentKind?
        public let tally: Tally
        public var id: String { agent?.rawValue ?? "all" }

        public init(agent: AgentKind?, tally: Tally) {
            self.agent = agent
            self.tally = tally
        }
    }

    /// One entry per agent reporting in the current window, "All agents" first.
    /// `keeping` is the rail's own selection: an agent whose last session has
    /// just aged out stays listed, so the tiles never shift under the pointer
    /// and the column the person is reading does not empty itself.
    public static func items(_ sessions: [AgentSession], keeping: AgentKind? = nil,
                             now: Date = Date()) -> [Item] {
        let current = SessionCurrency.current(sessions, now: now)
        var present = SessionFilter.presentAgents(current)
        if let keeping, !present.contains(keeping) { present.append(keeping) }
        return [Item(agent: nil, tally: tally(current))]
            + present.map { agent in Item(agent: agent, tally: tally(current.filter { $0.agent == agent })) }
    }

    /// A session needs you when it is blocked *or* broken — the same pairing
    /// the menu panel, the phone and the Watch use.
    public static func tally(_ sessions: [AgentSession]) -> Tally {
        let summary = TaskPresentationSummary(sessions: sessions)
        return Tally(total: sessions.count,
                     needsYou: summary.requiresInput + summary.error,
                     working: summary.thinking,
                     unread: summary.completeUnread)
    }

    public struct Group: Identifiable, Sendable {
        public let filter: DashboardSessionList.StatusFilter
        public let sessions: [AgentSession]
        public var id: String { filter.rawValue }

        public init(filter: DashboardSessionList.StatusFilter, sessions: [AgentSession]) {
            self.filter = filter
            self.sessions = sessions
        }
    }

    /// The column's sessions in the order they are read: what needs you, what
    /// is running, what came back unread, then the quiet ones. An empty group
    /// is dropped, so a heading never stands over nothing. The input keeps its
    /// own order inside each group — it arrives already ranked by
    /// `DashboardSessionList.visible`.
    public static func groups(_ sessions: [AgentSession]) -> [Group] {
        DashboardSessionList.StatusFilter.allCases.compactMap { filter in
            let rows = sessions.filter { filter.matches($0) }
            return rows.isEmpty ? nil : Group(filter: filter, sessions: rows)
        }
    }
}
