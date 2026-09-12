import SwiftUI
import VibeBuddyKit

/// How the dashboard cuts the stream into groups. Status is the default: the
/// phone's job is "what needs me, what is running, what finished".
enum DashboardGrouping: String, CaseIterable, Identifiable {
    case status, project, agent, none
    var id: String { rawValue }
    var title: String {
        switch self {
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

/// In-memory presentation selection. Never writes to the snapshot or action store.
struct DashboardFilters: Equatable {
    var project: String?
    var status: TaskPresentationState?
    var agent: AgentKind?
    var attention: SessionAttention?
    var grouping: DashboardGrouping = .status
    /// Off by default: a finished task older than `SessionRecency.window` is
    /// history, not today's list. Anything waiting on a person stays either way.
    var includeInactive = false

    var isActive: Bool { project != nil || status != nil || agent != nil || attention != nil }

    func matches(_ session: AgentSession) -> Bool {
        (project == nil || project == session.project)
            && (status == nil || status == session.presentationState)
            && (agent == nil || agent == session.agent)
            && (attention == nil || attention == session.effectiveAttention)
    }

    /// Everything the selection admits, newest first.
    func sessions(from sessions: [AgentSession], now: Date = Date()) -> [AgentSession] {
        let selected = sessions.filter(matches)
        let current = includeInactive ? selected : SessionRecency.current(selected, now: now)
        return current.sorted { $0.updatedAt > $1.updatedAt }
    }

    /// How many rows the recency window is holding back right now.
    func hiddenCount(from sessions: [AgentSession], now: Date = Date()) -> Int {
        includeInactive ? 0 : SessionRecency.inactiveCount(sessions.filter(matches), now: now)
    }

    func sections(from sessions: [AgentSession], now: Date = Date()) -> [DashboardSection] {
        let visible = self.sessions(from: sessions, now: now)
        switch grouping {
        case .none:
            return visible.isEmpty ? [] : [DashboardSection(id: "all", title: String(localized: "Tasks"), sessions: visible)]
        case .status:
            return StateGroups(visible).buckets.map {
                DashboardSection(id: $0.title, title: $0.title, sessions: $0.sessions)
            }
        case .project:
            return keyed(visible) { Self.projectTitle($0.project) }
        case .agent:
            return keyed(visible) { $0.agent.displayName }
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
        var projects = Set(sessions.map(\.project))
        if let project { projects.insert(project) }
        return projects.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    var summary: String {
        [project.map(DashboardFilters.projectTitle), status?.filterTitle,
         agent?.displayName, attention?.stateTitle].compactMap { $0 }.joined(separator: " · ")
    }

    static func projectTitle(_ project: String) -> String {
        project.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? String(localized: "No project") : project
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
                        ForEach(selection.projects(from: sessions), id: \.self) { project in
                            Text(DashboardFilters.projectTitle(project)).tag(String?.some(project))
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
                    Text("A finished task drops off the list a day after its last update. A task waiting on you always stays, however old it is.")
                }
                if selection.isActive || selection.grouping != .status || selection.includeInactive {
                    Section {
                        Button("Reset", role: .destructive) { selection = DashboardFilters() }
                    }
                }
            }
            .listStyle(.insetGrouped)
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
