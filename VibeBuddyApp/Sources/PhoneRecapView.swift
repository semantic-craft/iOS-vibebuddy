import SwiftUI
import VibeBuddyKit

struct PhoneRecapView: View {
    @EnvironmentObject private var dashboard: DashboardStore
    @ObservedObject var drafts: PhoneReaderDrafts
    let isUnobscured: Bool
    let newTask: () -> Void
    let openVoice: () -> Void
    @State private var selected: Selection?

    struct Selection: Hashable {
        let entry: RecapEntry
        let source: String
        let epoch: String
    }

    var body: some View {
        let displayedSource = dashboard.recapSourceID
        let displayedEpoch = dashboard.recapPairingEpoch
        List {
            Section {
                Text("Rounds that ended in the last 24 hours, after your last confirmed recap. Up to 12 rounds.")
                    .font(.subheadline).foregroundStyle(.secondary)
                if dashboard.state != .connected, dashboard.recap != nil {
                    Label("Offline · showing cached recap", systemImage: "wifi.slash")
                }
                if let recap = dashboard.recap {
                    Text("\(recap.entries.count) rounds · \(recap.failedCount) failed").font(.subheadline)
                    if let horizon = recap.horizon {
                        Text("After \(horizon.formatted())").font(.caption).foregroundStyle(.secondary)
                    }
                    if recap.entries.isEmpty { Text("No rounds in this recap") }
                    ForEach(recap.entries) { entry in
                        Button {
                            guard let source = displayedSource, source == dashboard.recapSourceID,
                                  displayedEpoch == dashboard.recapPairingEpoch else { return }
                            selected = Selection(entry: entry, source: source, epoch: displayedEpoch)
                        } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(entry.title).font(.headline)
                                Text("\(entry.agent.shortName) · \(entry.kind == .failed ? "Failed" : entry.isRead ? "Read" : "Unread") · \(entry.endedAt.formatted(date: .omitted, time: .shortened))")
                                    .font(.caption).foregroundStyle(.secondary)
                                ForEach(Array(entry.points.enumerated()), id: \.offset) { _, point in
                                    Text(point).font(.subheadline).foregroundStyle(.secondary)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .accessibilityIdentifier("phone-recap-" + entry.id)
                    }
                } else {
                    Text(dashboard.state == .connected ? "This Mac does not provide Recap yet." : "Waiting for Recap from your Mac…")
                }
            }
            Section {
                confirmation
            } footer: {
                Text("Confirming advances your recap position. Failed tasks still need attention.")
            }
        }
        .navigationTitle("Recap")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("New task", systemImage: "plus", action: newTask) } }
        .navigationDestination(item: $selected) { selected in
            PhoneRecapEntryView(selection: selected, drafts: drafts, isUnobscured: isUnobscured,
                                newTask: newTask, openVoice: openVoice)
        }
    }

    @ViewBuilder private var confirmation: some View {
        let state = dashboard.recapConfirmation
        let displayedSource = dashboard.recapSourceID
        let displayedEpoch = dashboard.recapPairingEpoch
        if state.sourceChanged {
            Text("The Mac or pairing changed. This confirmation stopped.")
        } else if state.isComplete {
            Text("Recap position confirmed")
        } else if state.batch != nil {
            Text("\(state.resolvedCount) / \(state.batch?.completions.count ?? 0) completion requests resolved")
        }
        if state.skippedCount > 0 {
            Text("\(state.skippedCount) rounds skipped because they expired or are unavailable.")
        }
        if state.canRetry {
            Button("Retry original batch") { dashboard.retryRecap() }
                .disabled(!dashboard.recapAvailable)
        } else if state.isRunning {
            ProgressView("Confirming original batch…")
        } else if let recap = dashboard.recap, !recap.entries.isEmpty {
            Button("Confirm these \(recap.entries.count) rounds") {
                guard let source = displayedSource else { return }
                dashboard.confirmRecap(recap, source: source, epoch: displayedEpoch)
            }.disabled(!dashboard.recapAvailable)
                .accessibilityIdentifier("phone-recap-confirm")
        }
    }
}

private struct PhoneRecapEntryView: View {
    let selection: PhoneRecapView.Selection
    @ObservedObject var drafts: PhoneReaderDrafts
    let isUnobscured: Bool
    let newTask: () -> Void
    let openVoice: () -> Void
    @EnvironmentObject private var dashboard: DashboardStore
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var reader = CompletionBodyReader()
    @State private var attempt = 0
    @State private var sending = false
    @State private var outcome: CompletionReadOutcome?
    @State private var showCurrent = false

    private var entry: RecapEntry { selection.entry }
    private var request: CompletionReadRequest? {
        guard entry.kind == .completed, let completion = entry.completionID else { return nil }
        return CompletionReadRequest(sourceID: selection.source, sessionID: entry.sessionID, completionID: completion)
    }
    private var refresh: CompletionBodyRefresh {
        CompletionBodyRefresh(request: request, context: dashboard.completionConnectionID, attempt: attempt,
                              isActive: scenePhase == .active && authorityMatches)
    }
    private var bodyText: String? { reader.body(for: refresh)?.text }
    private var authorityMatches: Bool {
        dashboard.completionSourceID == selection.source && dashboard.recapPairingEpoch == selection.epoch
            && ConnectionStore.pairingEpoch == selection.epoch
    }
    private var live: AgentSession? {
        guard authorityMatches else { return nil }
        return dashboard.allSessions.first { $0.id == entry.sessionID }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(entry.title).font(.title2)
                Text(entry.endedAt.formatted()).font(.caption)
                if !authorityMatches {
                    Text(dashboard.completionSourceID == nil
                         ? "Offline · showing the saved round. Actions are unavailable."
                         : "The source or pairing changed. This is the saved round; actions are unavailable.")
                } else if dashboard.state != .connected {
                    Text("Offline · showing the saved round. Actions are unavailable.")
                }
                if dashboard.recap?.entries.contains(where: { $0.id == entry.id }) != true {
                    Text("This round has left the current recap. Your selection is retained.").font(.caption)
                }
                Text("Recorded summary").font(.headline)
                ForEach(Array(entry.points.enumerated()), id: \.offset) { _, point in
                    Text(point).textSelection(.enabled)
                }
                if let request {
                    Divider()
                    if let bodyText, !bodyText.isEmpty {
                        Text(bodyText).font(.body).textSelection(.enabled)
                            .accessibilityIdentifier("phone-recap-result-body")
                        Text("Agent final response · this round · not independently verified").font(.caption)
                        Button("Copy result", systemImage: "doc.on.doc") { UIPasteboard.general.string = bodyText }
                    } else {
                        Text(reader.body(for: refresh)?.unavailableReason ?? (reader.state(for: refresh) == .loading
                             ? "Loading this round…" : "This round’s original response is unavailable."))
                        Button("Retry") { attempt += 1 }.disabled(!authorityMatches || dashboard.state != .connected)
                    }
                    Button("Mark this round as read") {
                        sending = true
                        Task {
                            outcome = await dashboard.readRecapCompletion(request, epoch: selection.epoch)
                            sending = false
                        }
                    }.disabled(sending || !authorityMatches || dashboard.state != .connected)
                    if let outcome { Text(outcomeText(outcome)).font(.caption) }
                } else { Text("Failed round · no completion reading state").font(.caption) }
                if live != nil {
                    Button("View current task") { guard authorityMatches else { return }; showCurrent = true }
                        .disabled(dashboard.state != .connected)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
        .navigationTitle("Recorded round")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("New task", systemImage: "plus", action: newTask) } }
        .task(id: refresh) {
            guard let request else { return }
            await reader.load(refresh) { await dashboard.recapBody(request, epoch: selection.epoch) }
        }
        .navigationDestination(isPresented: $showCurrent) {
            if let live {
                PhoneSessionReader(session: live, isUnobscured: isUnobscured && authorityMatches,
                                   drafts: drafts, draftScope: selection.source + "/" + selection.epoch,
                                   newTask: newTask, openVoice: openVoice)
            } else { Text("This task is no longer available") }
        }
    }

    private func outcomeText(_ outcome: CompletionReadOutcome) -> String {
        switch outcome {
        case .accepted, .alreadyAcknowledged: "Read confirmed by Mac"
        case .staleCompletion: "Skipped: this completion has expired"
        case .unavailable: "Skipped: this completion is unavailable"
        case .sourceMismatch: "The source changed; nothing else was confirmed"
        case .failed: "Confirmation failed. You can retry this same round."
        }
    }
}
