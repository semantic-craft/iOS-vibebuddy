import Foundation

/// Layout of the menu bar popover's session list.
///
/// The popover's job is "do I need to do anything?", so it is laid out in three
/// layers instead of one flat column that grows with every session:
///
/// 1. **Pinned** — sessions that need the user (`error`, `requiresInput`). They
///    belong to no group and are never hidden.
/// 2. **Groups** — everything else, grouped by agent. A collapsed group hides
///    only its finished/idle rows; a session that is still working stays
///    visible, the way a collapsed Slack section still shows its unread
///    channels. Group headers are pointless with a single agent, so they are
///    dropped (and collapsing is ignored) in that case.
/// 3. The Mac view caps the whole list's height and scrolls inside it.
///
/// Input order is preserved: the store already sorts most-urgent then
/// most-recent, and each group inherits that order. Groups themselves sort by
/// their most urgent row, then by recency.
public struct MenuSessionList: Equatable, Sendable {
    public struct Group: Equatable, Sendable, Identifiable {
        public let agent: AgentKind
        /// Every non-pinned session for this agent, in snapshot order.
        public let sessions: [AgentSession]
        public let isCollapsed: Bool

        public var id: AgentKind { agent }
        public var summary: TaskPresentationSummary { TaskPresentationSummary(sessions: sessions) }

        /// Rows the popover renders: all of them when expanded, only the ones
        /// still working when collapsed.
        public var visibleSessions: [AgentSession] {
            isCollapsed ? sessions.filter { $0.presentationState == .thinking } : sessions
        }
    }

    public let pinned: [AgentSession]
    public let groups: [Group]

    /// Headers (and therefore collapsing) only make sense with more than one agent.
    public var showsGroupHeaders: Bool { groups.count > 1 }
    public var isEmpty: Bool { pinned.isEmpty && groups.isEmpty }

    public init(_ sessions: [AgentSession], collapsedAgents: Set<AgentKind>) {
        pinned = sessions.filter { Self.isPinned($0) }
        let rest = sessions.filter { !Self.isPinned($0) }
        let byAgent = Dictionary(grouping: rest, by: \.agent)
        let multiple = byAgent.count > 1
        groups = byAgent
            .map { agent, sessions in
                Group(agent: agent, sessions: sessions,
                      isCollapsed: multiple && collapsedAgents.contains(agent))
            }
            .sorted { a, b in
                // Each group's first row is its most urgent + most recent one.
                guard let x = a.sessions.first, let y = b.sessions.first else { return false }
                if x.presentationState.attentionRank != y.presentationState.attentionRank {
                    return x.presentationState.attentionRank < y.presentationState.attentionRank
                }
                return x.updatedAt > y.updatedAt
            }
    }

    private static func isPinned(_ session: AgentSession) -> Bool {
        switch session.presentationState {
        case .error, .requiresInput: return true
        case .thinking, .completeUnread, .idle, .unassigned: return false
        }
    }
}
