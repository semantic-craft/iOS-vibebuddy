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
                            .font(.headline)
                        Label(status(task), systemImage: task.presentation.symbolName)
                            .font(.caption)
                        if task.completionID != link.completionID {
                            Text("Task status changed. This newer result has not been marked read.")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        if let summary = task.summary { Text(summary).font(.caption) }
                        if completionPending {
                            Text("Viewed — syncing with Mac").font(.caption2).foregroundStyle(.secondary)
                        }
                        if let alert = store.state?.alerts.first(where: { $0.sessionId == link.sessionID }),
                           task.presentation == .requiresInput {
                            WatchAlertCard(store: store, alert: alert, now: Date(), alsoWaiting: 0)
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
                        .font(.caption)
                }
                Button("Back to dashboard") { dismiss() }.padding(.top, 8)
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
