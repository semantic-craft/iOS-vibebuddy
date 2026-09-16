import SwiftUI
import VibeBuddyKit

struct PhoneSessionReader: View {
    let session: AgentSession
    var completionNotificationID: String? = nil
    let isUnobscured: Bool
    @ObservedObject var drafts: PhoneReaderDrafts
    let draftScope: String
    let newTask: () -> Void
    let openVoice: () -> Void
    @State private var isOnScreen = false
    @State private var showActivity = false
    @State private var choseCurrentTask = false
    @FocusState private var replyFocused: Bool
    @EnvironmentObject private var dashboard: DashboardStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var showHistory = false
    @State private var showChanges = false
    @StateObject private var resultReader = CompletionBodyReader()
    @State private var resultAttempt = 0
    @State private var resultIsVisible = false
    @State private var acknowledgedBodyID: String?
    private var resultKey: String { (dashboard.completionSourceID ?? "unknown") + "/" + session.id + "/" + (session.completionID ?? "working") }
    private var resultRefresh: CompletionBodyRefresh {
        CompletionBodyRefresh(sourceID: dashboard.completionSourceID, session: session,
                              context: dashboard.completionConnectionID, attempt: resultAttempt,
                              isActive: scenePhase == .active)
    }
    private var currentBody: CompletionBody? { resultReader.body(for: resultRefresh) }
    @AppStorage(VoiceSettings.companionEnabledKey) private var companionEnabled = false

    private var authorityIsCurrent: Bool { dashboard.readerAuthorityIsCurrent(scope: draftScope) }

    private var state: TaskPresentationState { session.presentationState }
    private var included: Bool { dashboard.buddySessionIDs.contains(session.id) }

    var body: some View {
        GeometryReader { geometry in
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .top, spacing: 10) {
                        AgentAvatar(agent: session.agent, size: 36)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(session.taskGoal)
                                .font(.title2.weight(.semibold))
                                .foregroundStyle(CompanionPalette.ink)
                                .lineLimit(2)
                            // The same line the row carries: the state word in
                            // its colour, then agent, project and branch.
                            HStack(spacing: 5) {
                                StatusDot(state: state, size: 6)
                                Text(ToolActivity.label(for: session))
                                    .foregroundStyle(CompanionPalette.status(state))
                                Text("·")
                                Text(session.agent.shortName)
                                if DashboardFilters.projectTitle(session.dashboardProjectIdentity, among: dashboard.allSessions.map(\.dashboardProjectIdentity)) != session.displayTitle {
                                    Text("·")
                                    Text(DashboardFilters.projectTitle(session.dashboardProjectIdentity, among: dashboard.allSessions.map(\.dashboardProjectIdentity)))
                                        .accessibilityLabel(session.dashboardProjectIdentity)
                                        .contextMenu {
                                            Text(session.dashboardProjectIdentity)
                                            Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = session.dashboardProjectIdentity }
                                        }
                                }
                                if let branch = session.branch {
                                    Text("·")
                                    Text(branch).font(CompanionType.mono(10)).lineLimit(1).truncationMode(.middle)
                                }
                            }
                            .font(CompanionType.font(11)).foregroundStyle(CompanionPalette.ink3)
                            .lineLimit(1)
                        }
                    }
                    Button("Conversation history") { showHistory = true }
                        .disabled(!authorityIsCurrent)
                        .accessibilityIdentifier("phone-open-history")
                    if session.completionNotice?.state == .pending {
                        Text("Preparing completion summary…")
                            .font(CompanionType.font(12)).foregroundStyle(CompanionPalette.ink2)
                    }
                    if let id = completionNotificationID,
                       !dashboard.matchesCompletionNotification(id, sessionID: session.id) {
                        if session.isUnboundCompletionNotification(id) {
                            Text("This notification does not identify a completion round. Review the current result before marking it read.")
                                .font(CompanionType.font(12)).foregroundStyle(CompanionPalette.ink2)
                            Button("Mark current result read") { if authorityIsCurrent { dashboard.acknowledgeDisplayedCompletion(session) } }
                                .buttonStyle(PhoneButtonStyle(kind: .quiet, size: .small))
                        } else {
                            Text("This task has moved on. You are viewing its current state, not the result from that notification.")
                                .font(CompanionType.font(12)).foregroundStyle(CompanionPalette.ink2)
                        }
                    }
                    if let summary = session.detailProgress, !summary.isEmpty {
                        Text(summary).font(CompanionType.font(14)).foregroundStyle(CompanionPalette.ink)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if session.status == .done, session.completionID != nil {
                        if let body = currentBody {
                            if let text = body.text {
                                Text(text).font(.body).foregroundStyle(CompanionPalette.ink)
                                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                                    .accessibilityIdentifier("phone-result-body")
                                .completionReadingVisibility { visible in
                                    resultIsVisible = visible; acknowledgeVisibleBody()
                                }
                                Text("Agent final response · this completion · not independently verified")
                                    .accessibilityIdentifier("phone-result-end")
                                    .font(CompanionType.font(10)).foregroundStyle(CompanionPalette.ink3)
                            } else if let reason = body.unavailableReason {
                                Text(LocalizedStringKey(reason)).font(CompanionType.font(11)).foregroundStyle(CompanionPalette.ink3)
                            }
                        } else if resultReader.state(for: resultRefresh) == .failed {
                            Text("Couldn’t load this result. Try again.").font(CompanionType.font(11))
                        } else { Text("Loading this completion…").font(CompanionType.font(11)) }
                        if currentBody?.text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false,
                           resultReader.state(for: resultRefresh) != .loading {
                            Button("Retry") { resultAttempt += 1 }
                                .buttonStyle(PhoneButtonStyle(kind: .quiet, size: .small))
                        }
                        Button(session.hasUnreadCompletion ? "Mark as read" : "Mark as unread") {
                            guard authorityIsCurrent else { return }
                            acknowledgedBodyID = resultKey
                            if session.hasUnreadCompletion {
                                dashboard.acknowledge(session.id, displayedCompletion: dashboard.completionRequest(for: session))
                            } else { dashboard.markUnread(session) }
                        }.buttonStyle(PhoneButtonStyle(kind: .quiet, size: .small))
                    }
                    Text(ToolActivity.label(for: session)).font(CompanionType.font(12))
                        .foregroundStyle(CompanionPalette.ink2)
                    Text(session.detailProgressSource).font(CompanionType.font(10))
                        .foregroundStyle(CompanionPalette.ink3)
                    if showActivity {
                        Button("Changes") { showChanges = true }.buttonStyle(PhoneButtonStyle(kind: .quiet, size: .small))
                        ToolLedgerView(session: session)
                        RecentOutputCard(output: dashboard.recentOutputs[session.id])
                        metaCard
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, PhoneMetrics.gutter)
                .padding(.bottom, 24)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(CompanionPalette.bg)
        .navigationTitle("Task")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button("New task", systemImage: "plus", action: newTask)
                    .accessibilityIdentifier("phone-reader-new-task")
                Menu {
                    Button("Copy result", systemImage: "doc.on.doc") { UIPasteboard.general.string = currentBody?.text }
                        .disabled(currentBody?.text?.isEmpty != false)
                        .accessibilityIdentifier("phone-copy-result")
                    Button("Activity and file changes", systemImage: "list.bullet") { showActivity.toggle() }
                    Button("Voice", systemImage: "waveform", action: openVoice)
                    if session.canJump { Button("Open current task on Mac") { if authorityIsCurrent { dashboard.jump(session.id) } } }
                    if companionEnabled { Button(included ? "Remove from buddy" : "Add to buddy") { if authorityIsCurrent { dashboard.toggleBuddy(session.id) } } }
                    Menu("Notifications") {
                        Button("Auto") { if authorityIsCurrent { dashboard.setAttention(session.id, nil) } }
                        ForEach(SessionAttention.allCases, id: \.self) { level in
                            Button(level.stateTitle) { if authorityIsCurrent { dashboard.setAttention(session.id, level) } }
                        }
                    }
                } label: { Image(systemName: "ellipsis.circle").accessibilityLabel("Reader actions") }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { dock(maxHeight: geometry.size.height * 0.38) }
        .navigationDestination(isPresented: $showHistory) {
            PhoneHistoryView(session: session, scope: draftScope, newTask: newTask)
        }
        .onAppear { isOnScreen = true; acknowledgeVisibleBody() }
        .onDisappear { isOnScreen = false }
        .onChange(of: completionNotificationID) { _, _ in choseCurrentTask = false }
        .onChange(of: isUnobscured) { _, _ in acknowledgeVisibleBody() }
        .tint(CompanionPalette.accent)
        .sheet(isPresented: $showChanges) {
            WorkspaceChangesView { scope, baseline, file in
                guard authorityIsCurrent else { return nil }
                return await dashboard.workspaceChanges(for: session, scope: scope, baseline: baseline, file: file)
            }
        }
        .task { if authorityIsCurrent { await dashboard.loadRecentOutput(session.id) } }
        .task(id: resultRefresh) {
            if currentBody?.text?.isEmpty != false { resultIsVisible = false }
            await resultReader.load(resultRefresh) { guard authorityIsCurrent else { return nil }; return await dashboard.completionBody(for: session) }
        }
        .onChange(of: currentBody) { _, _ in acknowledgeVisibleBody() }
        .onChange(of: scenePhase) { _, _ in acknowledgeVisibleBody() }
        .onChange(of: showChanges) { _, _ in acknowledgeVisibleBody() }
        }
    }

    private func acknowledgeVisibleBody() {
        guard authorityIsCurrent, scenePhase == .active, isOnScreen, isUnobscured, !showChanges, !showHistory, notificationIsCurrent, resultIsVisible, currentBody?.text?.isEmpty == false,
              session.hasUnreadCompletion, acknowledgedBodyID != resultKey else { return }
        acknowledgedBodyID = resultKey
        dashboard.acknowledge(session.id, displayedCompletion: dashboard.completionRequest(for: session))
    }

    private var notificationIsCurrent: Bool {
        choseCurrentTask || (completionNotificationID.map { dashboard.matchesCompletionNotification($0, sessionID: session.id) } ?? true)
    }

    private var draft: PhoneReaderDrafts.Draft { drafts.draft(scope: draftScope, session: session) }
    private var draftIsCurrent: Bool { draft.matches(session) }
    private var draftBinding: Binding<PhoneQuestionDraft> {
        Binding(get: { draft.question }, set: { value in
            guard authorityIsCurrent, let latest = dashboard.allSessions.first(where: { $0.id == session.id }), draft.matches(latest) else { return }
            drafts.update(scope: draftScope, session: session) { $0.question = value }
        })
    }

    private func dock(maxHeight: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if dashboard.state != .connected {
                Text("Offline · replies are unavailable").font(.caption)
            }
            if !draftIsCurrent {
                ScrollView { expiredDraft }.frame(maxHeight: maxHeight)
            } else if notificationIsCurrent {
                if session.status == .needsResponse {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) { decision }
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(maxHeight: maxHeight)
                } else if SessionActionSupport.resolve(for: session).isAvailable {
                    HStack(alignment: .bottom) {
                        TextField("Reply to this task", text: Binding(get: { draft.text }, set: { value in
                            drafts.update(scope: draftScope, session: session) { $0.text = value }
                        }), axis: .vertical)
                            .font(.body).lineLimit(1...4).focused($replyFocused)
                            .accessibilityIdentifier("phone-reader-reply")
                        Button("Send", systemImage: "arrow.up") { sendDraft() }
                            .disabled(draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !authorityIsCurrent || dashboard.phoneActionDisabled(for: session))
                    }
                    if let receipt = dashboard.phoneActionState(for: session) { Text(receipt.message).font(.caption) }
                }
            } else {
                Button("Open current task") { guard authorityIsCurrent else { return }; choseCurrentTask = true; acknowledgeVisibleBody() }
            }
        }
        .padding(.horizontal, PhoneMetrics.gutter).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CompanionPalette.bg)
    }

    private var expiredDraft: some View {
        VStack(alignment: .leading, spacing: 6) {
                Text("This draft belongs to an earlier task state. Discard it to reply to the current task.").font(.caption)
                if !draft.text.isEmpty { Text(draft.text).font(.body).textSelection(.enabled) }
                ForEach(draft.question.typed.keys.sorted(), id: \.self) { key in
                    Text(draft.question.typed[key] ?? "").font(.body).textSelection(.enabled)
                }
                ForEach(draft.question.picked.keys.sorted(), id: \.self) { key in
                    Text((draft.question.picked[key] ?? []).sorted().map { value in
                        draft.target.pendingQuestion?.items.first(where: { $0.id == key })?.options.first(where: { $0.value == value })?.label ?? value
                    }.joined(separator: ", "))
                        .font(.body).textSelection(.enabled)
                }
                Button("Discard old draft") { drafts.discard(scope: draftScope, session: session) }
        }
    }

    private func sendDraft() {
        let sent = draft
        Task {
            guard authorityIsCurrent else { return }
            let result = await dashboard.answer(session.id, answer: sent.text, expected: sent.target)
            if result == .received, authorityIsCurrent, let latest = dashboard.allSessions.first(where: { $0.id == session.id }), sent.matches(latest) {
                drafts.clearIfUnchanged(sent, scope: draftScope, session: session)
            }
        }
    }

    private func decide(_ approvalID: String, _ decision: ApprovalDecision) {
        Task {
            guard authorityIsCurrent else { return }
            _ = await dashboard.decideConfirmed(approvalID, decision)
        }
    }

    @ViewBuilder private var decision: some View {
        if let approval = session.pendingApproval {
            ApprovalBody(approval: approval)
            if ApprovalEligibility.approval(for: session) != nil {
                HStack {
                    Button("Approve") { decide(approval.id, .allow) }
                        .buttonStyle(PhoneButtonStyle(kind: .primary(CompanionPalette.accent)))
                    Button("Deny") { decide(approval.id, .deny) }
                        .buttonStyle(PhoneButtonStyle(kind: .primary(CompanionPalette.status(.error))))
                }.disabled(!authorityIsCurrent || dashboard.phoneActionDisabled(for: session))
            } else { Text(WaitHandling.resolve(for: session).message) }
        } else if let question = session.pendingQuestion {
            if WaitHandling.resolve(for: session) == .remoteAvailable {
                QuestionCardView(question: question, actionState: dashboard.phoneActionState(for: session), savedDraft: draftBinding) { answers in
                    guard authorityIsCurrent else { return .expired }
                    return await dashboard.answer(session.id, answers: answers, expected: draft.target)
                }.disabled(!authorityIsCurrent || dashboard.phoneActionDisabled(for: session))
            } else {
                Text(question.prompt)
                Text(WaitHandling.resolve(for: session).message)
            }
        } else { Text(WaitHandling.resolve(for: session).message) }
    }

    private var metaCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let model = session.model { meta("Model", model) }
            if let tokens = session.tokens { meta("Tokens", tokens.formatted()) }
            if let cost = session.estimatedCostUSD {
                meta("Cost", "\(session.costUSD == nil ? "≈ " : "")$" + String(format: "%.2f", cost))
            }
            if let effort = session.effort { meta("Effort", effort) }
            if let pr = session.prNumber { meta("PR", "#\(pr)") }
            if let worktree = session.worktree { meta("Worktree", worktree) }
            if let used = session.contextTokens, let window = session.contextWindow, window > 0 {
                ContextBar(used: used, window: window)
            }
            if let observation = session.observationDescription {
                HStack(spacing: 5) {
                    Label(observation, systemImage: "waveform.path.ecg")
                    if let last = session.lastObservedAt { Text("· \(PhoneRelativeTime.short(last))") }
                }
                .font(CompanionType.font(11)).foregroundStyle(CompanionPalette.ink3)
            }
            if let child = ToolActivity.childSummary(for: session) {
                Text(child).font(CompanionType.font(11)).foregroundStyle(CompanionPalette.ink2)
            }
            HStack(spacing: 4) {
                Image(systemName: session.status == .needsResponse ? "hourglass" : "clock")
                Text(session.statusSince, style: .timer).monospacedDigit()
            }
            .font(CompanionType.font(11)).foregroundStyle(CompanionPalette.ink3)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .companionCard()
    }

    private func meta(_ label: LocalizedStringKey, _ value: String) -> some View {
        HStack {
            Text(label).font(CompanionType.font(11)).foregroundStyle(CompanionPalette.ink2)
            Spacer()
            Text(value).font(CompanionType.mono(11)).foregroundStyle(CompanionPalette.ink).lineLimit(1).truncationMode(.middle)
        }
    }
}

/// Expandable bounded recent dialogue. The expanded text is the same slice
/// the collapsed preview came from — there is no fuller history behind it.
struct RecentOutputCard: View {
    let output: RecentOutput?
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                expanded.toggle()
            } label: {
                HStack {
                    Text("Recent output").font(CompanionType.font(11, .medium)).textCase(.uppercase).kerning(0.5)
                        .foregroundStyle(CompanionPalette.ink3)
                    Spacer()
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(CompanionPalette.ink3)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(expanded ? "Hide recent output" : "Show recent output")

            if let output {
                meta(output)
                if expanded {
                    entries(output)
                } else if let last = output.entries.last {
                    preview(last)
                }
                if !output.statusLine.isEmpty {
                    Text(output.statusLine)
                        .font(CompanionType.font(11))
                        .foregroundStyle(CompanionPalette.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text("Loading recent output…")
                    .font(CompanionType.font(11))
                    .foregroundStyle(CompanionPalette.ink3)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .companionCard()
    }

    private func meta(_ output: RecentOutput) -> some View {
        HStack(spacing: 6) {
            Text(output.sourceLabel)
            if let updatedAt = output.updatedAt {
                Text("·")
                Text(PhoneRelativeTime.short(updatedAt)).monospacedDigit()
            }
        }
        .font(CompanionType.font(11))
        .foregroundStyle(CompanionPalette.ink3)
    }

    @ViewBuilder
    private func entries(_ output: RecentOutput) -> some View {
        ForEach(Array(output.entries.enumerated()), id: \.offset) { _, entry in
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.role == "assistant" ? "Assistant" : "You")
                    .font(CompanionType.font(10, .medium))
                    .foregroundStyle(entry.role == "assistant" ? CompanionPalette.accent : CompanionPalette.ink3)
                Text(entry.text)
                    .font(CompanionType.font(13))
                    .foregroundStyle(CompanionPalette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
    }

    private func preview(_ entry: RecentOutputEntry) -> some View {
        Text(entry.text)
            .font(CompanionType.font(13))
            .foregroundStyle(CompanionPalette.ink)
            .lineLimit(3)
    }
}


private struct ContextBar: View {
    let used: Int
    let window: Int

    var body: some View {
        let frac = min(1.0, Double(used) / Double(max(window, 1)))
        VStack(alignment: .leading, spacing: 2) {
            ProgressView(value: frac).tint(color(frac))
            Text("\(short(used)) / \(short(window)) context")
                .font(CompanionType.font(10)).foregroundStyle(CompanionPalette.ink3).monospacedDigit()
        }
        .padding(.top, 2)
    }

    /// The quota bars' rule: the accent while there is room, the severity
    /// tints past 70 % and 90 %.
    private func color(_ f: Double) -> Color {
        f > 0.9 ? CompanionPalette.status(.error)
            : f > 0.7 ? CompanionPalette.status(.requiresInput) : CompanionPalette.accent
    }
    private func short(_ n: Int) -> String { n >= 1000 ? "\(n / 1000)k" : "\(n)" }
}

