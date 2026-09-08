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
            session.project.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? .unknown : .project(session.project)
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

    public init(_ sessions: [AgentSession], project: ProjectScope = .all,
                status: TaskPresentationState? = nil, query: String = "", selection: String? = nil) {
        total = sessions.count
        let counts = Dictionary(grouping: sessions, by: ProjectScope.of).mapValues(\.count)
        var scopes = counts.keys.sorted { lhs, rhs in
            switch (lhs, rhs) {
            case (.project(let a), .project(let b)): a.localizedStandardCompare(b) == .orderedAscending
            case (.project, _): true
            default: false
            }
        }
        // Keep a selected, now-empty project reachable until the user changes
        // scope; a disappearing snapshot must not silently select All projects.
        if project != .all && counts[project] == nil { scopes.append(project) }
        projects = [.init(id: .all, count: total)] + scopes.map { .init(id: $0, count: counts[$0, default: 0]) }
        let visible = SessionFilter.apply(sessions, status: nil, agent: nil, query: query)
            .filter { (project == .all || ProjectScope.of($0) == project)
                && (status == nil || $0.presentationState == status) }
            .sorted {
                $0.presentationState.attentionRank != $1.presentationState.attentionRank
                    ? $0.presentationState.attentionRank < $1.presentationState.attentionRank
                    : $0.updatedAt > $1.updatedAt
            }
        self.visible = visible
        selected = selection.flatMap { id in visible.first { $0.id == id } }
    }
}
