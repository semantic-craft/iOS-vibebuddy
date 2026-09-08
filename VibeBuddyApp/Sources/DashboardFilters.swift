import SwiftUI
import VibeBuddyKit

/// In-memory presentation selection. Never writes to the snapshot or action store.
struct DashboardFilters: Equatable {
    var project: String?
    var status: TaskPresentationState?
    var agent: AgentKind?
    var attention: SessionAttention?

    var isActive: Bool { project != nil || status != nil || agent != nil || attention != nil }

    func matches(_ session: AgentSession) -> Bool {
        (project == nil || project == session.project)
            && (status == nil || status == session.presentationState)
            && (agent == nil || agent == session.agent)
            && (attention == nil || attention == session.effectiveAttention)
    }

    func sessions(from sessions: [AgentSession]) -> [AgentSession] {
        sessions.filter(matches).sorted { $0.updatedAt < $1.updatedAt }
    }

    func projects(from sessions: [AgentSession]) -> [String] {
        // Keep an absent selection visible until the person clears or changes it.
        var projects = Set(sessions.map(\.project))
        if let project { projects.insert(project) }
        return projects.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    static func projectTitle(_ project: String) -> String {
        project.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? String(localized: "No project") : project
    }
}

struct DashboardFilterControls: View {
    @Binding var selection: DashboardFilters
    let sessions: [AgentSession]
    @Binding var showFilters: Bool
    let onDismiss: () -> Void

    private let statuses: [TaskPresentationState] = [.requiresInput, .error, .thinking, .completeUnread, .idle]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ScrollView(.horizontal) {
                HStack {
                    chip(String(localized: "All projects"), selected: selection.project == nil) { selection.project = nil }
                    ForEach(selection.projects(from: sessions), id: \.self) { project in
                        chip(DashboardFilters.projectTitle(project), selected: selection.project == project) {
                            selection.project = project
                        }
                    }
                }
            }
            .accessibilityLabel("Projects")
            ScrollView(.horizontal) {
                HStack {
                    chip(String(localized: "All statuses"), selected: selection.status == nil) { selection.status = nil }
                    ForEach(statuses, id: \.self) { status in
                        chip(status.filterTitle, selected: selection.status == status) { selection.status = status }
                    }
                }
            }
            .accessibilityLabel("Task status")
            HStack(alignment: .top) {
                Button { showFilters = true } label: {
                    Label("Agent & attention", systemImage: "line.3.horizontal.decrease")
                }
                Spacer()
                if selection.isActive {
                    Button("Clear filters") { selection = DashboardFilters() }
                }
            }
            .font(.subheadline)
            if selection.isActive {
                Text(summary).font(.caption).foregroundStyle(.secondary)
                    .accessibilityLabel(Text("Active filters: \(summary)"))
            }
        }
        .buttonStyle(.borderless)
        .sheet(isPresented: $showFilters, onDismiss: onDismiss) {
            NavigationStack {
                Form {
                    Picker("Agent", selection: $selection.agent) {
                        Text("All agents").tag(AgentKind?.none)
                        ForEach(AgentKind.allCases, id: \.self) { agent in
                            Text(agent.displayName).tag(AgentKind?.some(agent))
                        }
                    }
                    Picker("Attention", selection: $selection.attention) {
                        Text("All attention levels").tag(SessionAttention?.none)
                        ForEach(SessionAttention.allCases, id: \.self) { attention in
                            Text(attention.stateTitle).tag(SessionAttention?.some(attention))
                        }
                    }
                    if selection.isActive {
                        Section {
                            Text(summary)
                            Button("Clear filters") { selection = DashboardFilters() }
                        }
                    }
                }
                .navigationTitle("Filters")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showFilters = false } } }
            }
        }
    }

    private var summary: String {
        [selection.project.map(DashboardFilters.projectTitle), selection.status?.filterTitle,
         selection.agent?.displayName, selection.attention?.stateTitle].compactMap { $0 }.joined(separator: " · ")
    }

    private func chip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if selected { Image(systemName: "checkmark") }
                Text(title).fixedSize(horizontal: false, vertical: true)
            }
            .font(.subheadline.weight(selected ? .semibold : .regular))
            .padding(.horizontal, 12).padding(.vertical, 10)
            .frame(minHeight: 44)
            .background(selected ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.1), in: Capsule())
        }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private extension TaskPresentationState {
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
