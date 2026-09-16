import SwiftUI
import VibeBuddyKit

/// How the dashboard cuts the stream into groups. Status is the default: the
/// phone's job is "what needs me, what is running, what finished".
enum DashboardGrouping: String, CaseIterable, Identifiable {
    /// The bucket page's own layout (ticket 02): a Recents group, then the
    /// same rows again under their projects.
    case recent, status, project, agent, none
    var id: String { rawValue }
    var title: String {
        switch self {
        case .recent: String(localized: "Recents + projects")
        case .status: String(localized: "Status")
        case .project: String(localized: "Project")
        case .agent: String(localized: "Agent")
        case .none: String(localized: "None")
        }
    }
}

/// One rendered group of the dashboard list.
struct DashboardSection: Identifiable, Equatable {
    let id: String
    let title: String
    let sessions: [AgentSession]
}

extension AgentSession {
    var dashboardProjectIdentity: String {
        if let path = checkoutPath, !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return path
        }
        return project
    }
}

/// In-memory presentation selection. Never writes to the snapshot or action store.
struct DashboardFilters: Equatable {
    /// The inbox tile the list was opened from (ticket 01). A bucket admits a
    /// set of presentation states; `status` below is Customize's single pick
    /// and the two narrow together.
    var bucket: InboxBucket?
    var project: String?
    var status: TaskPresentationState?
    var agent: AgentKind?
    var attention: SessionAttention?
    var grouping: DashboardGrouping = .recent
    /// The search circle's text: a row must carry it in its title, project or
    /// branch. Cleared when the list is left.
    var query: String = ""
    /// Off by default: a session that is not current (`SessionCurrency`) is
    /// history, not today's list. Waiting, failed, running and followed-unread
    /// sessions stay either way.
    var includeInactive = false

    var isActive: Bool { bucket != nil || project != nil || status != nil || agent != nil || attention != nil }
    /// Customize's own picks, apart from the scope a tile or project row set:
    /// the list page shows these as a chip under its title.
    var hasCustomizePicks: Bool { status != nil || agent != nil || attention != nil }

    /// The list page's title: the bucket or project it was opened from, else
    /// every session.
    func scopeTitle(summary: TaskPresentationSummary, projects: [String] = []) -> String {
        if let project { return DashboardFilters.projectTitle(project, among: projects) }
        if let bucket { return bucket.title(for: summary) }
        return String(localized: "All sessions")
    }

    func matches(_ session: AgentSession) -> Bool {
        matchesQuery(session)
            && (bucket?.admits(session) ?? true)
            && (project == nil || project == session.dashboardProjectIdentity)
            && (status == nil || status == session.presentationState)
            && (agent == nil || agent == session.agent)
            && (attention == nil || attention == session.effectiveAttention)
    }

    private func matchesQuery(_ session: AgentSession) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return true }
        return [session.displayTitle, session.project, session.dashboardProjectIdentity, session.branch ?? ""]
            .contains { $0.localizedCaseInsensitiveContains(needle) }
    }

    /// Everything the selection admits, newest first.
    func sessions(from sessions: [AgentSession], now: Date = Date()) -> [AgentSession] {
        let selected = sessions.filter(matches)
        let current = includeInactive ? selected : SessionCurrency.current(selected, now: now)
        return current.sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Pending navigation has the same scope as this list, independent of
    /// its grouping and collapsed rows. The original input order breaks ties.
    func pendingSessions(from sessions: [AgentSession], now: Date) -> [AgentSession] {
        let selected = sessions.filter(matches)
        return PendingTasks.ordered(includeInactive ? selected : SessionCurrency.current(selected, now: now))
    }

    /// How many rows the recency window is holding back right now.
    func hiddenCount(from sessions: [AgentSession], now: Date = Date()) -> Int {
        includeInactive ? 0 : SessionCurrency.older(sessions.filter(matches), now: now).count
    }

    func sections(from sessions: [AgentSession], now: Date = Date()) -> [DashboardSection] {
        let visible = self.sessions(from: sessions, now: now)
        switch grouping {
        case .recent:
            // From a project row there is one project: its group alone. From a
            // bucket, Recents leads and every project repeats its rows.
            let byProject = projectSections(visible, projects: projects(from: sessions))
            if project != nil || visible.isEmpty { return byProject }
            return [DashboardSection(id: "recent", title: String(localized: "Recents"), sessions: visible)] + byProject
        case .none:
            return visible.isEmpty ? [] : [DashboardSection(id: "all", title: String(localized: "Tasks"), sessions: visible)]
        case .status:
            return StateGroups(visible).buckets.map {
                DashboardSection(id: $0.title, title: $0.title, sessions: $0.sessions)
            }
        case .project:
            return projectSections(visible, projects: projects(from: sessions))
        case .agent:
            return keyed(visible) { $0.agent.displayName }
        }
    }

    private func projectSections(_ sessions: [AgentSession], projects: [String]) -> [DashboardSection] {
        let labels = DashboardProjectLabel.labels(for: projects)
        return keyed(sessions) { $0.dashboardProjectIdentity }.map {
            DashboardSection(id: $0.id, title: Self.projectTitle($0.id, labels: labels), sessions: $0.sessions)
        }
    }

    /// Groups named by one of the session's own fields, ordered by name, each
    /// keeping the newest-first order the stream already has.
    private func keyed(_ sessions: [AgentSession], by name: (AgentSession) -> String) -> [DashboardSection] {
        var order: [String] = []
        var buckets: [String: [AgentSession]] = [:]
        for session in sessions {
            let key = name(session)
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(session)
        }
        return order.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .map { DashboardSection(id: $0, title: $0, sessions: buckets[$0] ?? []) }
    }

    func projects(from sessions: [AgentSession]) -> [String] {
        // Keep an absent selection visible until the person clears or changes it.
        var projects = Set(sessions.map(\.dashboardProjectIdentity))
        if let project { projects.insert(project) }
        return projects.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// Customize's picks in words; the scope (bucket or project) is the
    /// list's title and is not repeated here.
    var summary: String {
        [status?.filterTitle,
         agent?.displayName, attention?.stateTitle].compactMap { $0 }.joined(separator: " · ")
    }

    static func projectTitle(_ project: String, among projects: [String] = []) -> String {
        projectTitle(project, labels: DashboardProjectLabel.labels(for: projects + [project]))
    }

    static func projectTitle(_ project: String, labels: [String: DashboardProjectLabel]) -> String {
        guard !project.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return String(localized: "No project")
        }
        guard let label = labels[project] else { return project }
        return [label.title, label.parentPath].compactMap { $0 }.joined(separator: " · ")
    }
}

/// Cursor's "Customize": grouping, then the filters, then what the list is
/// allowed to hide. One sheet, so the dashboard itself carries no chip rows.
struct DashboardCustomizeSheet: View {
    @Binding var selection: DashboardFilters
    let sessions: [AgentSession]
    @Environment(\.dismiss) private var dismiss

    private let statuses: [TaskPresentationState] = [.requiresInput, .error, .thinking, .completeUnread, .idle]

    var body: some View {
        let projects = selection.projects(from: sessions)
        let labels = DashboardProjectLabel.labels(for: projects)
        VStack(spacing: 0) {
            PhoneSheetHeader(title: String(localized: "Customize")) { dismiss() }
            List {
                Section {
                    Picker("Group by", selection: $selection.grouping) {
                        ForEach(DashboardGrouping.allCases) { grouping in
                            Text(grouping.title).tag(grouping)
                        }
                    }
                    .pickerStyle(.navigationLink)
                } header: {
                    sectionTitle("Grouping")
                }
                Section {
                    Picker("Project", selection: $selection.project) {
                        Text("All").tag(String?.none)
                        ForEach(projects, id: \.self) { project in
                            Text(DashboardFilters.projectTitle(project, labels: labels))
                                .accessibilityLabel(project)
                                .tag(String?.some(project))
                        }
                    }
                    Picker("Status", selection: $selection.status) {
                        Text("All").tag(TaskPresentationState?.none)
                        ForEach(statuses, id: \.self) { status in
                            Text(status.filterTitle).tag(TaskPresentationState?.some(status))
                        }
                    }
                    Picker("Agent", selection: $selection.agent) {
                        Text("All").tag(AgentKind?.none)
                        ForEach(AgentKind.allCases, id: \.self) { agent in
                            Text(agent.displayName).tag(AgentKind?.some(agent))
                        }
                    }
                    Picker("Attention", selection: $selection.attention) {
                        Text("All").tag(SessionAttention?.none)
                        ForEach(SessionAttention.allCases, id: \.self) { attention in
                            Text(attention.stateTitle).tag(SessionAttention?.some(attention))
                        }
                    }
                } header: {
                    sectionTitle("Filter")
                }
                // A filter's current value is information, not an action: it
                // reads in ink, and the accent stays for what you switch.
                .tint(CompanionPalette.ink2)
                Section {
                    Toggle("Show tasks idle over 24 hours", isOn: $selection.includeInactive)
                } footer: {
                    Text("A finished task drops off the list a day after its last update. A task that is waiting on you, running, failed, or followed with an unread result always stays, however old it is.")
                }
                if selection.isActive || selection.grouping != .recent || selection.includeInactive {
                    Section {
                        Button("Reset", role: .destructive) { selection = DashboardFilters() }
                    }
                }
            }
            .listStyle(.insetGrouped)
            // The same row as Settings: the phone's face on the card ground,
            // so the system pickers and switch sit in the list's own type.
            .font(CompanionType.font(15))
            .foregroundStyle(CompanionPalette.ink)
            .listRowBackground(CompanionPalette.bg3)
            .phoneList()
        }
        .background(CompanionPalette.bg)
        .tint(CompanionPalette.accent)
        .toolbar(.hidden, for: .navigationBar)
    }

    private func sectionTitle(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .font(CompanionType.font(12, .medium))
            .foregroundStyle(CompanionPalette.ink3)
            .textCase(nil)
    }
}

extension TaskPresentationState {
    var filterTitle: String {
        switch self {
        case .requiresInput: String(localized: "Requires input")
        case .error: String(localized: "Error")
        case .thinking: String(localized: "Thinking")
        case .completeUnread: String(localized: "Complete, unread update")
        case .idle: String(localized: "Idle")
        case .unassigned: String(localized: "No assigned task")
        }
    }
}
