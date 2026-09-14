import Foundation
import VibeBuddyKit

/// Dashboard-only projection. Filtering never changes the shared snapshot or
/// chooses a replacement session when the current selection becomes hidden.
public struct DashboardSessionList: Sendable {
    public enum ProjectScope: Hashable, Sendable {
        case all
        case unknown
        case project(String)

        public static func of(_ session: AgentSession) -> Self {
            // `project` is display copy (often only a basename). The recorded
            // checkout is the identity shared with recentDirectories; keep its
            // exact spelling so distinct checkouts are never merged by name.
            if let path = session.checkoutPath,
               !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return .project(path)
            }
            return session.project.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? .unknown : .project(session.project)
        }
    }

    /// The chip row's groups. `needsYou` is the same word the menu panel, the
    /// phone and the Watch use: a failed session needs the user as much as a
    /// question does, so both land in one filter (`TaskPresentationSummary.needsYou`).
    public enum StatusFilter: String, CaseIterable, Hashable, Sendable {
        case needsYou, working, done, idle

        public var states: [TaskPresentationState] {
            switch self {
            case .needsYou: [.requiresInput, .error]
            case .working: [.thinking]
            case .done: [.completeUnread]
            case .idle: [.idle]
            }
        }

        public func matches(_ session: AgentSession) -> Bool {
            states.contains(session.presentationState)
        }
    }

    public struct Project: Identifiable, Sendable {
        public let id: ProjectScope
        public let count: Int
    }

    public let projects: [Project]
    public let visible: [AgentSession]
    public let selected: AgentSession?
    public let total: Int
    public let summary: TaskPresentationSummary
    public let globalPending: [AgentSession]
    public let pending: [AgentSession]
    public let olderCount: Int

    public init(_ sessions: [AgentSession], project: ProjectScope = .all,
                status: StatusFilter? = nil, query: String = "", selection: String? = nil,
                showOlder: Bool = false, recentDirectories: [String] = [], now: Date = Date()) {
        let current = SessionCurrency.current(sessions, now: now)
        summary = TaskPresentationSummary(sessions: current)
        total = current.count
        olderCount = sessions.count - current.count
        globalPending = PendingTasks.ordered(current)
        let counts = Dictionary(grouping: globalPending, by: ProjectScope.of).mapValues(\.count)
        let latest = Dictionary(grouping: sessions, by: ProjectScope.of)
            .mapValues { $0.map(\.updatedAt).max() ?? .distantPast }
        var ranks: [ProjectScope: Int] = [:]
        for (index, session) in globalPending.enumerated() where ranks[ProjectScope.of(session)] == nil {
            ranks[ProjectScope.of(session)] = index
        }
        var scopes = Set(sessions.map(ProjectScope.of))
        for directory in recentDirectories where !directory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            scopes.insert(.project(directory))
        }
        if project != .all { scopes.insert(project) }
        let orderedScopes = scopes.sorted { lhs, rhs in
            if let l = ranks[lhs], let r = ranks[rhs] { return l < r }
            if ranks[lhs] != nil { return true }
            if ranks[rhs] != nil { return false }
            let l = latest[lhs] ?? .distantPast, r = latest[rhs] ?? .distantPast
            if l != r { return l > r }
            switch (lhs, rhs) {
            case (.project(let a), .project(let b)): return a.localizedStandardCompare(b) == .orderedAscending
            case (.project, _): return true
            default: return false
            }
        }
        projects = [.init(id: .all, count: globalPending.count)]
            + orderedScopes.map { .init(id: $0, count: counts[$0, default: 0]) }
        let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidates = (showOlder ? sessions : current).filter { session in
            let matchesQuery = search.isEmpty || [session.displayTitle, session.project, session.checkoutPath ?? "", session.branch ?? "", session.summary ?? ""]
                .contains { $0.localizedStandardContains(search) }
            return matchesQuery && (project == .all || ProjectScope.of(session) == project)
                && (status?.matches(session) ?? true)
        }
        pending = PendingTasks.ordered(candidates)
        let pendingIDs = Set(pending.map(\.id))
        visible = pending + candidates.filter { !pendingIDs.contains($0.id) }.sorted { $0.updatedAt > $1.updatedAt }
        // Reading may remove a row from Unread; retain its live detail until
        // explicit navigation. Never freeze stale permissions or substitute a task.
        selected = selection.flatMap { id in sessions.first { $0.id == id } }
    }
}
