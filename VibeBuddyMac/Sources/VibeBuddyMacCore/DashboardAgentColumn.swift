import Foundation
import VibeBuddyKit

/// The agent column's session groups. Who is reporting and what each of them
/// is carrying is `AgentRoster` in the Kit — the Mac's rail and the phone's
/// strip read the same tallies (ADR-0031); what belongs here is the split the
/// Mac's column alone shows, because only it has the height for headings.
public enum DashboardAgentColumn {
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
