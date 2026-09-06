import SwiftUI
import VibeBuddyKit

/// The iPhone dashboard as a message stream (docs/design/mac-companion-redesign.md,
/// rounds 6–8): every session is a message from its agent, oldest at the top
/// and the newest beside the composer. A message that needs you carries its
/// keys; replying to a message fixes whom the text goes to and what it means.
struct DashboardView: View {
    @EnvironmentObject private var connection: ConnectionStore
    @EnvironmentObject private var dashboard: DashboardStore
    @EnvironmentObject private var voice: VoiceChat
    @AppStorage(VoiceSettings.companionEnabledKey) private var companionEnabled = false
    @State private var showSettings = false
    @State private var showNewTask = false
    @State private var newTaskDraft = ""
    @State private var highlightId: String?
    @State private var detailId: String?
    @State private var replyTo: String?

    /// Oldest first, so the newest sits by the composer like a conversation.
    private var stream: [AgentSession] { dashboard.allSessions.sorted { $0.updatedAt < $1.updatedAt } }
    private var replyTarget: AgentSession? { replyTo.flatMap { id in dashboard.allSessions.first { $0.id == id } } }
    private var detailSession: AgentSession? { detailId.flatMap { id in dashboard.allSessions.first { $0.id == id } } }
    /// The paired Mac's name is the page title; the demo has no Mac.
    private var macTitle: String {
        let name = connection.pairing?.macName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !name.isEmpty { return name }
        return connection.demo ? String(localized: "Demo") : "Mac"
    }

    var body: some View {
        ScrollViewReader { proxy in
        List {
            ForEach(stream) { session in
                MessageRow(session: session,
                           isSelected: highlightId == session.id,
                           isReplyTarget: replyTo == session.id,
                           onOpen: { detailId = session.id },
                           onReply: { replyTo = session.id })
                    .id(session.id)
                    .swipeActions(edge: .leading, allowsFullSwipe: true) { attentionSwipeButtons(session) }
                    .contextMenu { attentionMenu(session) }
                    .listRowInsets(.init(top: 5, leading: 16, bottom: 5, trailing: 16))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(CompanionPalette.bg)
        .scrollDismissesKeyboard(.interactively)
        .onChange(of: dashboard.focusedSessionId) { _, _ in focus(proxy) }
        .onChange(of: dashboard.groups) { _, _ in
            if dashboard.focusedSessionId != nil { focus(proxy) }
            if let id = replyTo, !dashboard.allSessions.contains(where: { $0.id == id }) { replyTo = nil }
        }
        .onChange(of: stream.last?.id) { _, id in
            if let id, dashboard.focusedSessionId == nil { withAnimation(.smooth) { proxy.scrollTo(id, anchor: .bottom) } }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                BuddyView(groups: dashboard.groups, pulse: dashboard.cuePulse,
                          voice: .init(voice.phase),
                          companionEnabled: companionEnabled,
                          buddyScopeCount: dashboard.buddySessionIDs.count) {
                    voice.toggle()
                }
                if voice.phase != .idle || voice.errorText != nil {
                    VoiceStrip(voice: voice)
                }
            }
            .background(CompanionPalette.bg)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            StreamComposer(target: replyTarget,
                           clearTarget: { replyTo = nil },
                           send: send(_:))
                .background(CompanionPalette.bg)
        }
        .animation(.smooth, value: dashboard.groups)
        .animation(.smooth, value: replyTo)
        .overlay {
            if dashboard.groups.isEmpty { EmptyStateView(state: dashboard.state) }
        }
        .navigationTitle(macTitle)
        // The cat's bubble is the header now; a large title above it only
        // spends a screen's worth of blank space (and on iOS 26 hides behind
        // the inset).
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // The title is the paired Mac: a status dot, its name, and a menu
            // holding everything about the link (address, reconnect, forget).
            // "New task" lives in the composer; nothing else earns the bar.
            ToolbarItem(placement: .principal) {
                MacTitleMenu(title: macTitle, pairing: connection.pairing, demo: connection.demo,
                             state: dashboard.state,
                             reconnect: { if let p = connection.pairing { dashboard.start(p) } },
                             copyAddress: {
                                 if let p = connection.pairing {
                                     UIPasteboard.general.string = "\(p.host):\(String(p.port))"
                                     dashboard.showToast(String(localized: "Address copied"))
                                 }
                             },
                             disconnect: { connection.clear(); dashboard.forgetPairing() })
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { showSettings = true } label: { Image(systemName: "gearshape") }
                    .accessibilityLabel("Settings")
            }
        }
        .tint(CompanionPalette.accent)
        .sheet(isPresented: $showNewTask) { NewTaskSheet(dashboard: dashboard, initialPrompt: newTaskDraft) }
        .sheet(isPresented: $showSettings) {
            // A sheet doesn't inherit the presenter's environment objects, so
            // re-inject `voice` — Settings restarts a live session on change.
            SettingsView()
                .environmentObject(voice)
                .environmentObject(dashboard)
        }
        .sheet(isPresented: $voice.showConsent) { VoiceConsentSheet(voice: voice) }
        .sheet(item: Binding(get: { detailSession.map { DetailTarget(id: $0.id) } },
                             set: { detailId = $0?.id })) { target in
            if let session = dashboard.allSessions.first(where: { $0.id == target.id }) {
                SessionDetailSheet(session: session, onReply: { replyTo = session.id; detailId = nil })
                    .environmentObject(dashboard)
                    .onAppear { dashboard.acknowledge(session.id) }
            }
        }
        .overlay(alignment: .bottom) {
            if let toast = dashboard.toast {
                Text(toast)
                    .font(CompanionType.font(13, .bold))
                    .foregroundStyle(CompanionPalette.ink)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(CompanionPalette.bg3, in: Capsule())
                    .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
                    .padding(.bottom, 90)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.smooth, value: dashboard.toast)
        .task(id: connection.pairing) {
            if let pairing = connection.pairing { dashboard.start(pairing) }
        }
        .task { if connection.demo { dashboard.startDemo() } }
        .onDisappear { dashboard.stop() }
        }
    }

    private struct DetailTarget: Identifiable { let id: String }

    /// What the composer's text does, decided by the message it replies to.
    private func send(_ text: String) {
        guard let target = replyTarget else {
            newTaskDraft = text
            showNewTask = true
            return
        }
        dashboard.answer(target.id, answer: text)
        replyTo = nil
    }

    /// Scroll to and briefly highlight the session a deep link asked to open.
    /// No-ops (leaving the request pending) until that session is in the list, so
    /// a cold-start link still lands once the first snapshot arrives.
    private func focus(_ proxy: ScrollViewProxy) {
        guard let id = dashboard.focusedSessionId,
              dashboard.allSessions.contains(where: { $0.id == id }) else { return }
        dashboard.acknowledge(id)
        dashboard.clearFocus()
        withAnimation(.smooth) { proxy.scrollTo(id, anchor: .center) }
        highlightId = id
        Task {
            try? await Task.sleep(for: .seconds(2))
            withAnimation { if highlightId == id { highlightId = nil } }
        }
    }
}

extension DashboardView {
    /// The swipe offers the two levels the row is not already at: Follow (be
    /// reminded until its completion is read; everything interrupts) and Mute
    /// (approvals and questions show silently; nothing else interrupts).
    @ViewBuilder
    fileprivate func attentionSwipeButtons(_ session: AgentSession) -> some View {
        if session.effectiveAttention != .followed {
            Button { dashboard.setAttention(session.id, .followed) } label: {
                Label(SessionAttention.followed.actionTitle, systemImage: SessionAttention.followed.symbol)
            }
            .tint(.orange)
        }
        if session.effectiveAttention != .muted {
            Button { dashboard.setAttention(session.id, .muted) } label: {
                Label(SessionAttention.muted.actionTitle, systemImage: SessionAttention.muted.symbol)
            }
            .tint(.gray)
        }
    }

    /// The long-press shows all three plus Automatic, the current choice checked.
    /// Automatic is the daemon's own inference: followed for ten minutes after
    /// you drove the session, normal otherwise.
    fileprivate func attentionMenu(_ session: AgentSession) -> some View {
        Picker(selection: Binding(get: { session.attentionOverride },
                                  set: { dashboard.setAttention(session.id, $0) })) {
            Label(String(localized: "Automatic"), systemImage: "wand.and.stars")
                .tag(SessionAttention?.none)
            ForEach(SessionAttention.allCases, id: \.self) { level in
                Label(level.actionTitle, systemImage: level.symbol).tag(SessionAttention?.some(level))
            }
        } label: {
            Label(String(localized: "Attention"), systemImage: session.effectiveAttention.symbol)
        }
        .pickerStyle(.menu)
    }
}

extension SessionAttention {
    /// The verb on a swipe / menu item, and the noun in the row's accessibility label.
    var actionTitle: String {
        switch self {
        case .followed: String(localized: "Follow")
        case .normal: String(localized: "Normal")
        case .muted: String(localized: "Mute")
        }
    }
    var stateTitle: String {
        switch self {
        case .followed: String(localized: "Followed")
        case .normal: String(localized: "Normal")
        case .muted: String(localized: "Muted")
        }
    }
    var symbol: String {
        switch self {
        case .followed: "bell.badge"
        case .normal: "bell"
        case .muted: "bell.slash"
        }
    }
}


/// What a reply to a session means, from the session's own state
/// (mobile-watch-task-control: answer, instruction, continue and new task are
/// four different actions and the sender must see which one this is).
enum ReplyMeaning: Equatable {
    case answer, instruction, continuation, newTask

    init(target: AgentSession?) {
        guard let target else { self = .newTask; return }
        if let q = target.pendingQuestion, q.isAnswerable { self = .answer; return }
        self = target.status == .done ? .continuation : .instruction
    }

    var verb: LocalizedStringKey {
        switch self {
        case .answer: "Answer"
        case .instruction: "Send instruction"
        case .continuation: "Continue"
        case .newTask: "New task"
        }
    }

    func placeholder(for target: AgentSession?) -> String {
        switch self {
        case .answer: String(localized: "Answer \(target?.displayTitle ?? "")…")
        case .instruction: String(localized: "Instruction for \(target?.displayTitle ?? "")…")
        case .continuation: String(localized: "Continue \(target?.displayTitle ?? "") with…")
        case .newTask: String(localized: "New task…")
        }
    }

    /// Instructions and continuations travel through the Codex app-server; a
    /// Claude Code session has no such channel from the phone yet.
    func unsupportedReason(for target: AgentSession?) -> String? {
        guard let target, self == .instruction || self == .continuation, target.agent != .codex else { return nil }
        return String(localized: "\(target.agent.displayName) sessions can't take instructions from the phone yet — use the terminal.")
    }
}

/// One session as a message from its agent (round 7): avatar with the status
/// dot, `title · agent · time`, then `ACTIVITY — summary`; a pending approval
/// or question is answered inside the bubble.
private struct MessageRow: View {
    let session: AgentSession
    let isSelected: Bool
    let isReplyTarget: Bool
    let onOpen: () -> Void
    let onReply: () -> Void
    @EnvironmentObject private var dashboard: DashboardStore

    private var state: TaskPresentationState { session.presentationState }
    private var canReply: Bool {
        if let q = session.pendingQuestion, q.isAnswerable { return true }
        return session.agent == .codex
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Button(action: onOpen) {
                AgentAvatar(agent: session.agent, size: 30)
                    .overlay(alignment: .bottomTrailing) {
                        Circle().fill(CompanionPalette.status(state))
                            .frame(width: 11, height: 11)
                            .overlay(Circle().strokeBorder(CompanionPalette.bg, lineWidth: 2))
                            .offset(x: 2, y: 2)
                    }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(session.displayTitle), \(state.label). Open details")
            VStack(alignment: .leading, spacing: 8) {
                Button(action: onOpen) { whoLine }.buttonStyle(.plain)
                body_
                if let approval = session.pendingApproval { approvalBlock(approval) }
                if let question = session.pendingQuestion { questionBlock(question) }
                if let child = ToolActivity.childSummary(for: session) {
                    Text(child).font(CompanionType.font(11, .semibold)).foregroundStyle(CompanionPalette.ink2)
                        .monospacedDigit().lineLimit(1)
                }
                actions
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(CompanionPalette.bg3, in: UnevenRoundedRectangle(
                topLeadingRadius: 4, bottomLeadingRadius: 16, bottomTrailingRadius: 16, topTrailingRadius: 16,
                style: .continuous))
            .overlay {
                if isSelected || isReplyTarget {
                    UnevenRoundedRectangle(topLeadingRadius: 4, bottomLeadingRadius: 16,
                                           bottomTrailingRadius: 16, topTrailingRadius: 16, style: .continuous)
                        .strokeBorder(CompanionPalette.accent, lineWidth: 2)
                }
            }
            .shadow(color: .black.opacity(0.04), radius: 2, y: 1)
        }
    }

    private var whoLine: some View {
        HStack(spacing: 5) {
            Text(session.displayTitle).fontWeight(.heavy).foregroundStyle(CompanionPalette.ink)
            if session.name != nil { Text(session.project) }
            Text("·"); Text(session.agent.shortName)
            if let branch = session.branch { Text(branch).font(CompanionType.mono(9)) }
            if session.effectiveAttention != .normal {
                Image(systemName: session.effectiveAttention == .followed ? "bell.badge.fill" : "bell.slash.fill")
                    .foregroundStyle(session.effectiveAttention == .followed
                                     ? CompanionPalette.status(.requiresInput) : CompanionPalette.ink3)
                    .accessibilityLabel(session.effectiveAttention.stateTitle)
            }
            Spacer(minLength: 6)
            Text(session.updatedAt, style: .relative).monospacedDigit()
        }
        .font(CompanionType.font(10, .bold))
        .foregroundStyle(CompanionPalette.ink2)
        .lineLimit(1)
    }

    private var body_: some View {
        (Text(ToolActivity.label(for: session)).foregroundStyle(CompanionPalette.status(state)).fontWeight(.heavy)
         + Text(" — ").foregroundStyle(CompanionPalette.ink3)
         + Text(session.summary ?? "").foregroundStyle(CompanionPalette.ink))
            .font(CompanionType.font(13, .semibold))
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private func approvalBlock(_ approval: PendingApproval) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("wants to \(CompanionCopy.requestVerb(approval)) · \(approval.tool)")
                .font(CompanionType.font(10, .heavy)).textCase(.uppercase).kerning(0.5)
                .foregroundStyle(CompanionPalette.status(.requiresInput))
            ApprovalBody(approval: approval)
            if !approval.isAnswerable {
                Label("You're at the Mac — answer this in the agent's own prompt.", systemImage: "keyboard")
                    .font(CompanionType.font(11, .semibold)).foregroundStyle(CompanionPalette.ink2)
            } else {
                HStack(spacing: 8) {
                    SplitApproveButton(
                        approve: { dashboard.decide(approval.id, .allow) },
                        always: { dashboard.decide(approval.id, .alwaysAllow) },
                        session: { dashboard.decide(approval.id, .allowSession) })
                    Button("Deny") { dashboard.decide(approval.id, .deny) }
                        .buttonStyle(PillButtonStyle(kind: .ghost))
                }
                if let rule = approval.suggestedRule {
                    Text("Always allow adds \(rule) to Claude's own rules.")
                        .font(CompanionType.font(10, .semibold)).foregroundStyle(CompanionPalette.ink3)
                }
            }
            if session.agent == .grok, let mode = approval.permissionMode, mode != "bypassPermissions" {
                Label {
                    Text("Grok will still ask in the terminal after Allow (permission mode: \(mode)). Set permission_mode = \"always-approve\" to approve from here.")
                } icon: {
                    Image(systemName: "terminal")
                }
                .font(CompanionType.font(10, .semibold)).foregroundStyle(CompanionPalette.ink3)
            }
        }
    }

    @ViewBuilder private func questionBlock(_ question: PendingQuestion) -> some View {
        if question.isAnswerable {
            QuestionCardView(question: question) { answers in dashboard.answer(session.id, answers: answers) }
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Text(question.prompt).font(CompanionType.font(14, .heavy)).foregroundStyle(CompanionPalette.ink)
                Label("You're at the Mac — answer this in the agent's own prompt.", systemImage: "keyboard")
                    .font(CompanionType.font(11, .semibold)).foregroundStyle(CompanionPalette.ink2)
            }
        }
    }

    @ViewBuilder private var actions: some View {
        if canReply || session.canJump {
            HStack(spacing: 6) {
                if canReply {
                    Button(action: onReply) { Label("Reply", systemImage: "arrowshape.turn.up.left") }
                        .buttonStyle(PillButtonStyle(kind: isReplyTarget ? .filled(CompanionPalette.accent) : .soft, size: .small))
                }
                if session.canJump {
                    Button(session.jumpsToDesktopThread ? "Open thread" : "Jump") { dashboard.jump(session.id) }
                        .buttonStyle(PillButtonStyle(kind: .soft, size: .small))
                }
            }
        }
    }
}

/// Round 8: the composer says whom the text goes to and what it means. With
/// a reply target the banner names both; without one the text is a new task.
private struct StreamComposer: View {
    let target: AgentSession?
    let clearTarget: () -> Void
    let send: (String) -> Void
    @State private var draft = ""
    @FocusState private var focused: Bool

    private var meaning: ReplyMeaning { ReplyMeaning(target: target) }
    private var unsupported: String? { meaning.unsupportedReason(for: target) }
    private var canSend: Bool {
        unsupported == nil && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 6) {
            if let target {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Replying to \(target.displayTitle) · \(target.presentationState.label)")
                            .font(CompanionType.font(10, .heavy)).foregroundStyle(CompanionPalette.ink2)
                        Text(unsupported ?? target.summary ?? ToolActivity.label(for: target))
                            .font(CompanionType.font(12, .bold))
                            .foregroundStyle(unsupported == nil ? CompanionPalette.ink : CompanionPalette.status(.error))
                            .lineLimit(2)
                    }
                    Spacer(minLength: 0)
                    Button(action: clearTarget) {
                        Image(systemName: "xmark").font(.system(size: 11, weight: .black)).foregroundStyle(CompanionPalette.ink3)
                            .frame(width: 26, height: 26)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Cancel reply")
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(CompanionPalette.bg3, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2).fill(CompanionPalette.status(target.presentationState))
                        .frame(width: 4).padding(.vertical, 8).padding(.leading, 2)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            HStack(spacing: 8) {
                TextField(meaning.placeholder(for: target), text: $draft, axis: .vertical)
                    .font(CompanionType.font(14, .semibold))
                    .lineLimit(1...4)
                    .focused($focused)
                    .padding(.leading, 14).padding(.vertical, 8)
                    .onSubmit(submit)
                Button(action: submit) {
                    HStack(spacing: 5) {
                        Text(meaning.verb)
                        Image(systemName: "arrow.up").font(.system(size: 12, weight: .black))
                    }
                }
                .buttonStyle(PillButtonStyle(kind: .filled(canSend ? CompanionPalette.accent : CompanionPalette.ink3), size: .small))
                .disabled(!canSend)
                .padding(.trailing, 6)
            }
            .background(CompanionPalette.bg3, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .shadow(color: .black.opacity(0.06), radius: 6, y: 2)
        }
        .padding(.horizontal, 12).padding(.top, 6).padding(.bottom, 8)
        .onChange(of: target?.id) { _, id in if id != nil { focused = true } }
    }

    private func submit() {
        guard canSend else { return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        send(text)
        draft = ""
        focused = false
    }
}

/// Everything the bubble keeps behind the avatar: the session's numbers,
/// context, health, how much it may interrupt you, and the ways to reach it.
private struct SessionDetailSheet: View {
    let session: AgentSession
    let onReply: () -> Void
    @EnvironmentObject private var dashboard: DashboardStore
    @Environment(\.dismiss) private var dismiss
    @AppStorage(VoiceSettings.companionEnabledKey) private var companionEnabled = false

    private var state: TaskPresentationState { session.presentationState }
    private var included: Bool { dashboard.buddySessionIDs.contains(session.id) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 10) {
                        AgentAvatar(agent: session.agent, size: 40)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(session.displayTitle).font(CompanionType.font(22, .black)).foregroundStyle(CompanionPalette.ink)
                            HStack(spacing: 6) {
                                if session.name != nil { Text(session.project) }
                                AgentBadge(agent: session.agent)
                                if let branch = session.branch { Text(branch).font(CompanionType.mono(10)) }
                            }
                            .font(CompanionType.font(11, .bold)).foregroundStyle(CompanionPalette.ink2)
                        }
                    }
                    HStack(spacing: 6) {
                        Image(systemName: state.symbolName).font(.system(size: 10, weight: .bold))
                        Text(state.label)
                    }
                    .font(CompanionType.font(12, .heavy))
                    .foregroundStyle(CompanionPalette.status(state))
                    .padding(.horizontal, 12).padding(.vertical, 4)
                    .background(CompanionPalette.status(state).opacity(0.14), in: Capsule())
                    if let summary = session.summary, !summary.isEmpty {
                        Text(summary).font(CompanionType.font(14, .semibold)).foregroundStyle(CompanionPalette.ink)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    metaCard
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Notifications").font(CompanionType.font(10, .heavy)).textCase(.uppercase).kerning(0.6)
                            .foregroundStyle(CompanionPalette.ink3)
                        Picker("Attention", selection: Binding(get: { session.attentionOverride },
                                                               set: { dashboard.setAttention(session.id, $0) })) {
                            Text("Auto").tag(SessionAttention?.none)
                            ForEach(SessionAttention.allCases, id: \.self) { level in
                                Text(level.stateTitle).tag(SessionAttention?.some(level))
                            }
                        }
                        .pickerStyle(.segmented)
                    }
                    HStack(spacing: 8) {
                        if session.canJump {
                            Button(session.jumpsToDesktopThread ? "Open thread in ChatGPT" : "Jump to terminal") {
                                dashboard.jump(session.id)
                            }
                            .buttonStyle(PillButtonStyle(kind: .filled(CompanionPalette.accent)))
                        }
                        Button { onReply() } label: { Label("Reply", systemImage: "arrowshape.turn.up.left") }
                            .buttonStyle(PillButtonStyle(kind: .soft))
                        if companionEnabled {
                            Button { dashboard.toggleBuddy(session.id) } label: {
                                Label(included ? "In buddy's context" : "Add to buddy", systemImage: included ? "waveform.circle.fill" : "waveform.circle")
                            }
                            .buttonStyle(PillButtonStyle(kind: .soft))
                        }
                    }
                }
                .padding(20)
            }
            .background(CompanionPalette.bg)
            .navigationTitle("Session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
        .tint(CompanionPalette.accent)
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
                    if let last = session.lastObservedAt { Text("· \(last, style: .relative)") }
                }
                .font(CompanionType.font(10, .semibold)).foregroundStyle(CompanionPalette.ink3)
            }
            if let child = ToolActivity.childSummary(for: session) {
                Text(child).font(CompanionType.font(11, .semibold)).foregroundStyle(CompanionPalette.ink2)
            }
            HStack(spacing: 4) {
                Image(systemName: session.status == .needsResponse ? "hourglass" : "clock")
                Text(session.statusSince, style: .timer).monospacedDigit()
            }
            .font(CompanionType.font(10, .semibold)).foregroundStyle(CompanionPalette.ink3)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .companionCard()
    }

    private func meta(_ label: LocalizedStringKey, _ value: String) -> some View {
        HStack {
            Text(label).font(CompanionType.font(11, .bold)).foregroundStyle(CompanionPalette.ink2)
            Spacer()
            Text(value).font(CompanionType.mono(11)).foregroundStyle(CompanionPalette.ink).lineLimit(1).truncationMode(.middle)
        }
    }
}

/// A thin per-session context-window usage bar: used / window, coloured by fill.
private struct ContextBar: View {
    let used: Int
    let window: Int

    var body: some View {
        let frac = min(1.0, Double(used) / Double(max(window, 1)))
        VStack(alignment: .leading, spacing: 2) {
            ProgressView(value: frac).tint(color(frac))
            Text("\(short(used)) / \(short(window)) context")
                .font(.caption2).foregroundStyle(.tertiary).monospacedDigit()
        }
        .padding(.top, 2)
    }

    private func color(_ f: Double) -> Color { f > 0.9 ? .red : f > 0.7 ? .orange : .blue }
    private func short(_ n: Int) -> String { n >= 1000 ? "\(n / 1000)k" : "\(n)" }
}

/// The navigation title as a menu about the paired Mac: a dot for the link
/// state, the Mac's name, and inside it the address, reconnect, copy and
/// forget. Tapping the name is the one place to manage the connection.
private struct MacTitleMenu: View {
    let title: String
    let pairing: PairingPayload?
    let demo: Bool
    let state: DashboardStore.ConnectionState
    let reconnect: () -> Void
    let copyAddress: () -> Void
    let disconnect: () -> Void

    var body: some View {
        Menu {
            if let pairing {
                Text(verbatim: "\(statusText) · \(pairing.host):\(String(pairing.port))")   // no "9,877" grouping
                Button(action: reconnect) { Label("Reconnect", systemImage: "arrow.clockwise") }
                Button(action: copyAddress) { Label("Copy address", systemImage: "doc.on.doc") }
            }
            Button(role: .destructive, action: disconnect) {
                Label(demo ? LocalizedStringKey("Exit demo") : LocalizedStringKey("Disconnect"), systemImage: "eject")
            }
        } label: {
            HStack(spacing: 6) {
                Circle().fill(color).frame(width: 8, height: 8)
                Text(title)
                    .font(CompanionType.font(17, .bold))
                    .foregroundStyle(CompanionPalette.ink)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(CompanionPalette.ink3)
            }
        }
        .accessibilityLabel(Text(verbatim: "\(title), \(statusText)"))
    }

    private var color: Color {
        switch state {
        case .connected: CompanionPalette.accent
        case .connecting: CompanionPalette.status(.requiresInput)
        case .failed: CompanionPalette.status(.error)
        }
    }

    private var statusText: String {
        switch state {
        case .connecting: String(localized: "Connecting")
        case .connected: String(localized: "Connected")
        case .failed: String(localized: "Reconnecting")
        }
    }
}

private struct EmptyStateView: View {
    @State private var showMacHelp = false
    let state: DashboardStore.ConnectionState

    var body: some View {
        switch state {
        case .connecting:
            ContentUnavailableView("Connecting to your Mac", systemImage: "antenna.radiowaves.left.and.right")
        case .connected:
            ContentUnavailableView(
                "No active sessions", systemImage: "moon.zzz",
                description: Text("Start a Claude Code or Codex session and it'll show up here."))
        case .failed(let message):
            ContentUnavailableView {
                Label("Disconnected", systemImage: "wifi.exclamationmark")
            } description: {
                Text(message)
                Text("Check that the Mac app is running, both devices are on the same local network, and Local Network access is enabled in Settings.")
            } actions: {
                Button("Need the Mac companion?") { showMacHelp = true }
            }
            .sheet(isPresented: $showMacHelp) { MacCompanionSetupSheet() }
        }
    }
}

/// Inline consent before the voice companion's first use: you tapped to talk, so
/// the ask is here, not buried in Settings. Continuing persists the opt-in; it
/// does not open the mic — the next tap starts the call.
private struct VoiceConsentSheet: View {
    @ObservedObject var voice: VoiceChat
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text("Tap the pet to talk with your selected AI provider: Qwen (DashScope), OpenAI, or Gemini (Google).")
                    .foregroundStyle(.secondary)
                Text("When you start a voice conversation, your microphone audio and selected session context (project names, agent type, status, and summaries) are sent directly to that provider using your own API key. The key stays in Keychain and nothing passes through a vibebuddy server.")
                    .foregroundStyle(.secondary)
                Text("Continuing keeps the mic off until your next tap.")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button { voice.enableCompanion(); dismiss() } label: {
                    Text("Continue").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()
            .navigationTitle("Voice companion")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() } } }
        }
        .presentationDetents([.medium])
    }
}
