import SwiftUI
import VibeBuddyKit

/// Reads the daemon's bounded round ledger. Navigation never acknowledges a
/// completion, and historical points never borrow the current task's output.
struct MacRecapView: View {
    @ObservedObject var model: MenuBarModel
    @State private var selected: String?
    @Environment(\.controlActiveState) private var controlActiveState

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Recap").font(MacTheme.font(26, .semibold))
            Text("After your last confirmation · Last 24 hours · Up to 12 rounds")
                .font(MacTheme.font(12)).foregroundStyle(MacTheme.ink2)
            TimelineView(.periodic(from: .now, by: 5)) { context in
                if let updated = model.recapUpdatedAt {
                    HStack {
                        if context.date.timeIntervalSince(updated) > 10 {
                            Label("Showing cached recap", systemImage: "wifi.slash")
                        }
                        Text("Updated")
                        Text(updated, style: .time)
                    }
                    .font(MacTheme.font(11)).foregroundStyle(MacTheme.ink3)
                }
            }
            TimelineView(.periodic(from: .now, by: 5)) { _ in confirmation }
            if let recap = model.recap {
                if let horizon = recap.horizon {
                    HStack {
                        Text("Recap starts after")
                        Text(horizon, format: .dateTime.year().month().day().hour().minute())
                    }.font(MacTheme.font(11)).foregroundStyle(MacTheme.ink3)
                }
                Text("\(recap.entries.count) rounds · \(recap.failedCount) failed")
                    .font(MacTheme.font(12, .medium))
                if let selected, !recap.entries.contains(where: { $0.id == selected }) {
                    Label("The selected round has left this recap.", systemImage: "clock.arrow.circlepath")
                        .font(MacTheme.font(12)).foregroundStyle(MacTheme.ink2)
                }
                if recap.entries.isEmpty {
                    QuietEmptyState(title: "No new recap", message: "Ended rounds will appear here within the recap window.", systemName: "clock.arrow.circlepath")
                } else {
                    List(selection: $selected) {
                        ForEach(recap.entries) { entry in
                            VStack(alignment: .leading, spacing: 8) {
                                HStack(alignment: .firstTextBaseline) {
                                    Image(systemName: entry.kind == .failed ? "exclamationmark.triangle" : "checkmark.circle")
                                    Text(entry.title).font(MacTheme.font(14, .semibold))
                                    Spacer()
                                    Text(entry.endedAt, style: .time).font(MacTheme.mono(11))
                                }
                                HStack {
                                    Text(entry.agent.displayName)
                                    Text(entry.project.isEmpty ? String(localized: "Unknown project") : entry.project)
                                        .lineLimit(1).truncationMode(.middle)
                                    Spacer()
                                    Text(entry.kind == .failed ? "Failed" : entry.isRead ? "Read" : "Completed")
                                }
                                .font(MacTheme.font(11)).foregroundStyle(selected == entry.id && controlActiveState == .key ? Color.white.opacity(0.9) : MacTheme.ink2)
                                if selected == entry.id {
                                    ForEach(Array(entry.points.enumerated()), id: \.offset) { _, point in
                                        Text(point).font(MacTheme.font(13)).textSelection(.enabled)
                                    }
                                    if entry.points.isEmpty {
                                        Text("No summary was recorded for this round.")
                                            .font(MacTheme.font(12)).foregroundStyle(selected == entry.id && controlActiveState == .key ? Color.white.opacity(0.8) : MacTheme.ink3)
                                    }
                                    Text(entry.endedAt, format: .dateTime.year().month().day().hour().minute())
                                        .font(MacTheme.mono(11)).foregroundStyle(selected == entry.id && controlActiveState == .key ? Color.white.opacity(0.8) : MacTheme.ink3)
                                    if model.sessions.contains(where: { $0.id == entry.sessionID }) {
                                        Button { DashboardRoute.openSession(id: entry.sessionID) } label: {
                                            Text("Open current task").underline()
                                        }
                                            .buttonStyle(.plain)
                                            .foregroundStyle(controlActiveState == .key ? Color.white : MacTheme.accentText)
                                            .accessibilityIdentifier("mac-recap-open-current")
                                        Text("Opens the live task, which may have moved to a newer round.")
                                            .font(MacTheme.font(11)).foregroundStyle(selected == entry.id && controlActiveState == .key ? Color.white.opacity(0.8) : MacTheme.ink3)
                                    } else {
                                        Text("The current task is unavailable. This round remains here.")
                                            .font(MacTheme.font(11)).foregroundStyle(selected == entry.id && controlActiveState == .key ? Color.white.opacity(0.8) : MacTheme.ink3)
                                    }
                                }
                            }
                            .foregroundStyle(selected == entry.id && controlActiveState == .key ? Color.white : MacTheme.ink)
                            .padding(.vertical, 8)
                            .tag(entry.id)
                            .accessibilityIdentifier("mac-recap-round-" + entry.id)
                        }
                    }
                    .listStyle(.plain)
                }
            } else {
                QuietEmptyState(title: "Recap unavailable", message: "Waiting for an authoritative recap from this Mac.", systemName: "clock.badge.questionmark")
            }
        }
        .padding(24).foregroundStyle(MacTheme.ink)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityIdentifier("mac-recap-reader")
        .onChange(of: model.completionSourceID) { _, _ in selected = nil }
    }

    /// Outside the entry list: a successful horizon write can empty that list
    /// while exact-round acknowledgements still need a retry.
    private var confirmation: some View {
        let state = model.recapConfirmation
        let displayed = model.recap
        let sourceID = model.completionSourceID
        return VStack(alignment: .leading, spacing: 8) {
            Text("Confirms completed results in this recap as read across devices. This does not approve the work or resolve failures.")
                .font(MacTheme.font(11)).foregroundStyle(MacTheme.ink3)
            if state.isRunning {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Confirming this recap…")
                }
            } else if state.sourceChanged {
                Text("The source changed. The previous confirmation was stopped.")
                    .foregroundStyle(MacTheme.ink2)
            } else if state.canRetry {
                Text("Confirmation is incomplete. Retry keeps the original rounds, even when this recap is empty.")
                    .foregroundStyle(MacTheme.ink2)
                Text("\(state.resolvedCount) of \(state.batch?.completions.count ?? 0) completion requests handled")
                    .foregroundStyle(MacTheme.ink3)
                Button("Retry this confirmation") { model.retryRecapConfirmation() }
                    .disabled(!model.recapAuthorityAvailable)
                    .accessibilityIdentifier("mac-recap-retry")
            } else if state.isComplete {
                Text("This confirmation was accepted. Lists update from the Mac’s snapshot.")
                    .foregroundStyle(MacTheme.ink2)
                if state.skippedCount > 0 {
                    Text("\(state.skippedCount) older rounds were no longer available to mark read.")
                        .foregroundStyle(MacTheme.ink3)
                }
            }
            if !state.isRunning && !state.canRetry {
                Button("Confirm this recap") {
                    if let displayed { model.confirmRecap(displayed, sourceID: sourceID) }
                }
                .disabled(displayed?.entries.isEmpty != false || !model.recapAuthorityAvailable)
                .accessibilityIdentifier("mac-recap-confirm")
            }
            if !model.recapAuthorityAvailable {
                Text("Confirmation is unavailable until this Mac supplies a fresh snapshot.")
                    .foregroundStyle(MacTheme.ink3)
            }
        }
        .font(MacTheme.font(12))
        .accessibilityIdentifier("mac-recap-confirmation-status")
    }

}
