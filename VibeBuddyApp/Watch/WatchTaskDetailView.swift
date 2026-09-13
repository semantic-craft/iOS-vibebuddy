import SwiftUI
import VibeBuddyKit

/// One session, opened on purpose: from a row, a complication, or the tap on
/// a mirrored notification. The URL's session stays selected even if another
/// becomes more urgent, and the body is re-read from the live state on every
/// render — so a wait that was answered elsewhere turns into "no longer
/// waiting" here rather than staying a live-looking card.
///
/// Three shapes. A task the projection carries (followed, or a result) gets
/// the task header, and its card when it is waiting. A waiting session the
/// projection carries only as an alert gets the card alone. Anything else is
/// unavailable, and says so. An opened completion retains only its reading
/// content when it leaves the list. Appearing *views*: it tells the Mac the wait was seen
/// and queues the exact-round read of a completion — never an approval or an
/// answer, which are the card's buttons and nothing else.
struct WatchTaskDetailView: View {
    @ObservedObject var store: WatchStateStore
    let link: WatchTaskLink
    @State private var retainedResult: WatchFollowedTask?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                if let task = link.task(in: store.state) {
                    taskBody(task)
                } else if let alert = link.alert(in: store.state) {
                    alertBody(alert)
                } else if let retainedResult,
                          store.state?.sourceID == link.sourceID,
                          store.state?.pairingEpoch == link.pairingEpoch {
                    // Keep the opened result readable when acknowledgement
                    // removes its row. Never retain an approval or Stop control.
                    VStack(alignment: .leading, spacing: 8) {
                        Text(retainedResult.title).font(CompanionType.font(15, .semibold))
                        Text("Previously viewed result")
                            .font(CompanionType.font(10)).foregroundStyle(CompanionPalette.ink2)
                        if let summary = retainedResult.detailSummary ?? retainedResult.summary {
                            Text(summary).font(CompanionType.font(12))
                        }
                        if completionPending {
                            Text("Viewed — syncing with Mac").font(CompanionType.font(10))
                        }
                        footer
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text(unavailableText)
                        .font(CompanionType.font(12))
                        .foregroundStyle(CompanionPalette.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Button("Back to dashboard") { dismiss() }
                    .buttonStyle(CompanionButtonStyle(kind: .quiet, size: .wide))
                    .padding(.top, 8)
            }
            .navigationTitle("Task")
        }
    }

    private func taskBody(_ task: WatchFollowedTask) -> some View {
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
            if let alert = link.alert(in: store.state), task.presentation == .requiresInput {
                WatchAlertCard(store: store, alert: alert, now: Date(), alsoWaiting: 0)
            } else {
                // The alert card already carries the control for a
                // waiting session; showing it twice on one screen
                // would offer the same turn two buttons.
                WatchStopControl(store: store, task: task)
            }
            footer
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            if task.presentation == .completeUnread, task.completionID == link.completionID {
                retainedResult = task
            }
            store.viewed(link)
        }
    }

    /// A waiting session the projection knows only as an alert — not
    /// followed, so no task header: the card is the whole story.
    private func alertBody(_ alert: WatchAlert) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            WatchAlertCard(store: store, alert: alert, now: Date(), alsoWaiting: 0)
            footer
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { store.viewed(link) }
    }

    @ViewBuilder
    private var footer: some View {
        if let state = store.state {
            WatchFooter(state: state,
                        connection: state.connection(now: Date(), phoneReachable: store.isPhoneReachable),
                        now: Date())
        }
    }

    /// A bounded list cannot tell whether an absent task was resolved or
    /// simply fell outside the window. Point to the full task on another device.
    private var unavailableText: LocalizedStringResource {
        if let state = store.state, state.sourceID == link.sourceID, state.pairingEpoch == link.pairingEpoch,
           state.relay == .live {
            return "This task is not in the current Watch list. Open it on your iPhone or Mac."
        }
        return "This task is unavailable. Return to the dashboard for current tasks."
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
