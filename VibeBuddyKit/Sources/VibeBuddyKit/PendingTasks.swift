import Foundation

/// The caller supplies the visible scope. Grouping/collapse do not participate;
/// all surfaces share the Needs-you priority and stable newest-first order.
public enum PendingTasks {
    public static func ordered(_ sessions: [AgentSession]) -> [AgentSession] {
        let ordered = sessions.enumerated().sorted {
            $0.element.updatedAt == $1.element.updatedAt
                ? $0.offset < $1.offset : $0.element.updatedAt > $1.element.updatedAt
        }.map(\.element)
        let groups = StateGroups(ordered)
        return groups.needsYou + groups.done.filter { $0.presentationState == .completeUnread }
    }
}

/// Local navigation only. Remember the rounds already visited so removing a
/// read result cannot restart the tour at an unresolved wait. No acknowledgements
/// or task operations live here. Reset when the source or filter scope changes.
public struct PendingTaskNavigation: Sendable {
    private struct Identity: Hashable, Sendable {
        let sessionID: String
        let completionID: String?
        let waitID: String?
        let statusSince: Date
        init(_ session: AgentSession) {
            sessionID = session.id
            completionID = session.completionID
            waitID = session.pendingQuestion?.id ?? session.pendingApproval?.id
            statusSince = session.statusSince
        }
    }
    private var visited: Set<Identity> = []
    private var lastSelection: Identity?
    public init() {}

    /// Capture an explicit selection while it still belongs to the queue.
    /// Reading may remove it before the user presses Next for the first time.
    public mutating func select(_ session: AgentSession, in ordered: [AgentSession]) {
        let identity = Identity(session)
        if let index = ordered.firstIndex(where: { Identity($0) == identity }) {
            visited = Set(ordered.prefix(through: index).map(Identity.init))
        } else {
            visited = [identity]
        }
        lastSelection = identity
    }

    public mutating func next(in ordered: [AgentSession], after current: AgentSession?) -> AgentSession? {
        let currentIdentity = current.map(Identity.init)
        // A manually selected task starts a tour from its position, rather than
        // jumping back to the first item. A read marker does not change identity.
        if let currentIdentity, currentIdentity != lastSelection {
            if let index = ordered.firstIndex(where: { Identity($0) == currentIdentity }) {
                visited = Set(ordered.prefix(through: index).map(Identity.init))
            } else {
                visited = [currentIdentity]
            }
        }
        if let currentIdentity { visited.insert(currentIdentity) }
        let others = ordered.filter { $0.id != current?.id }
        guard !others.isEmpty else { return nil }
        let next: AgentSession
        if let unvisited = others.first(where: { !visited.contains(Identity($0)) }) {
            next = unvisited
        } else {
            // Every remaining item was visited, but unresolved waits remain
            // eligible for another explicit tour. Never return the current row.
            visited = Set(currentIdentity.map { [$0] } ?? [])
            next = others[0]
        }
        lastSelection = Identity(next)
        visited.insert(Identity(next))
        return next
    }
}
