import SwiftUI
import VibeBuddyKit

/// The URL's task stays selected even if another task becomes more urgent.
struct WatchTaskDetailView: View {
    @ObservedObject var store: WatchStateStore
    let link: WatchTaskLink
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                if let task = link.task(in: store.state) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(task.title.isEmpty ? String(localized: "Unnamed task") : task.title)
                            .font(CompanionType.font(15, .semibold))
                            .foregroundStyle(CompanionPalette.ink)
                        HStack(spacing: 5) {
                            if let agent = task.agent {
                                AgentAvatar(agent: agent, size: 16)
                                    .accessibilityHidden(true)
                            }
                            Text(task.sourceName)
                                .font(CompanionType.font(10))
                                .foregroundStyle(CompanionPalette.ink2)
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(task.sourceName)
                        HStack(spacing: 6) {
                            StatusDot(state: task.presentation)
                            Text(status(task))
                                .font(CompanionType.font(12, .medium))
                                .foregroundStyle(CompanionPalette.status(task.presentation))
                        }
                        .accessibilityElement(children: .combine)
                        if task.completionID != link.completionID {
                            Text("Task status changed. This newer result has not been marked read.")
                                .font(CompanionType.font(10)).foregroundStyle(CompanionPalette.ink2)
                        }
                        if let summary = task.detailSummary ?? task.summary {
                            CompanionHairline()
                            Text(summary)
                                .font(CompanionType.font(12))
                                .foregroundStyle(CompanionPalette.ink)
                        }
                        if completionPending {
                            Text("Viewed — syncing with Mac")
                                .font(CompanionType.font(10)).foregroundStyle(CompanionPalette.ink2)
                        }
                        if let alert = store.state?.alerts.first(where: { $0.sessionId == link.sessionID }),
                           task.presentation == .requiresInput {
                            WatchAlertCard(store: store, alert: alert, now: Date(), alsoWaiting: 0)
                        } else {
                            // The alert card already carries the control for a
                            // waiting session; showing it twice on one screen
                            // would offer the same turn two buttons.
                            WatchStopControl(store: store, task: task)
                        }
                        if let state = store.state {
                            WatchFooter(state: state,
                                        connection: state.connection(now: Date(), phoneReachable: store.isPhoneReachable),
                                        now: Date())
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .onAppear { store.viewed(link) }
                } else {
                    Text("This task is unavailable. Return to the dashboard for current tasks.")
                        .font(CompanionType.font(12))
                        .foregroundStyle(CompanionPalette.ink2)
                }
                Button("Back to dashboard") { dismiss() }
                    .buttonStyle(CompanionButtonStyle(kind: .quiet, size: .wide))
                    .padding(.top, 8)
            }
            .navigationTitle("Task")
        }
    }
    private var completionPending: Bool { store.completionQueue.links.contains(link) }
    private func status(_ task: WatchFollowedTask) -> String {
        switch task.presentation {
        case .requiresInput: String(localized: "Needs response")
        case .error: String(localized: "Error")
        case .completeUnread: String(localized: "Done, unread")
        case .thinking: String(localized: "Working")
        default: String(localized: "Read")
        }
    }
}
