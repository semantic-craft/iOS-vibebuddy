import Foundation
import VibeBuddyKit

/// Mac menu projection only: stable project grouping over the whole snapshot.
/// The menu shows every session it is given — narrowing is the search field's
/// job, not this type's.
public struct MenuProjectList: Sendable {
    public struct Project: Identifiable, Sendable {
        // Optional identity keeps an unknown project distinct from a project named "Unknown project".
        public let id: String?
        public var title: String { id ?? "Unknown project" }
        public let actionable: [AgentSession]
        public let others: [AgentSession]
        public let isExpanded: Bool
        public var count: Int { actionable.count + others.count }
        public var visibleSessions: [AgentSession] { actionable + (isExpanded ? others : []) }
        public var expansionKey: String { id.map { "project:\($0)" } ?? "unknown" }
    }

    public enum EmptyState: Equatable, Sendable {
        case noSessions
    }

    public let projects: [Project]
    public let summary: TaskPresentationSummary
    public let visibleCount: Int
    public let emptyState: EmptyState?

    public init(_ sessions: [AgentSession], expandedProjects: Set<String> = []) {
        summary = TaskPresentationSummary(sessions: sessions)
        visibleCount = sessions.count
        emptyState = sessions.isEmpty ? .noSessions : nil
        var keys: [String?] = []
        var grouped: [String?: [AgentSession]] = [:]
        for session in sessions {
            let key: String? = session.project.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? nil : session.project
            if grouped[key] == nil { keys.append(key) }
            grouped[key, default: []].append(session)
        }
        let ordered = keys.map { key in
            let members = grouped[key, default: []]
            let actionable = members.filter { $0.presentationState == .error || $0.presentationState == .requiresInput }
            let others = members.filter { $0.presentationState != .error && $0.presentationState != .requiresInput }
            return Project(id: key, actionable: actionable, others: others,
                           isExpanded: expandedProjects.contains(key.map { "project:\($0)" } ?? "unknown"))
        }
        projects = ordered.filter { !$0.actionable.isEmpty } + ordered.filter { $0.actionable.isEmpty }
    }
}
