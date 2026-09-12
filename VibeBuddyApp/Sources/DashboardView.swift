import Combine
import SwiftUI
import VibeBuddyKit

/// The phone's dashboard (ADR-0014): a page of grouped task rows under a
/// floating row of glyph buttons, with one composer at the foot. Filtered
/// sessions retain their message rows and explicit reply targets; filtering
/// never changes the Buddy scope, subscription, or action authority.
struct DashboardView: View {
    @State private var detailCompletionNotificationID: String?
    @EnvironmentObject private var connection: ConnectionStore
    @EnvironmentObject private var dashboard: DashboardStore
    @EnvironmentObject private var voice: VoiceChat
    @AppStorage(VoiceSettings.companionEnabledKey) private var companionEnabled = false
    @StateObject private var settingsConnectionTest = VoiceConnectionTest()
    @State private var showSettings = false
    @State private var showQuota = false
    @State private var showNewTask = false
    @State private var newTaskDraft = ""
    @State private var highlightId: String?
    @State private var detailId: String?
    @State private var replyTo: String?
    @State private var filters = DashboardFilters()
    @State private var showFilters = false
    @State private var waitingForFilterDismiss = false
    @State private var collapsed: Set<String> = []
    /// The recency window moves with the clock, so the list re-cuts on a slow
    /// tick as well as on every snapshot.
    @State private var now = Date()
    private let clock = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    private var sections: [DashboardSection] { filters.sections(from: dashboard.allSessions, now: now) }
    private var stream: [AgentSession] { filters.sessions(from: dashboard.allSessions, now: now) }
    private var hiddenCount: Int { filters.hiddenCount(from: dashboard.allSessions, now: now) }
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
            header
                .listRowInsets(.init(top: 2, leading: PhoneMetrics.gutter, bottom: 4, trailing: PhoneMetrics.gutter))
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            if !dashboard.allSessions.isEmpty && dashboard.state != .connected {
                Label("Showing last snapshot. Reconnect to update tasks.", systemImage: "wifi.exclamationmark")
                    .font(CompanionType.font(12)).foregroundStyle(CompanionPalette.ink2)
                    .listRowInsets(.init(top: 0, leading: PhoneMetrics.gutter, bottom: 12, trailing: PhoneMetrics.gutter))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }
            if dashboard.allSessions.isEmpty {
                EmptyStateView(state: dashboard.state)
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            } else if stream.isEmpty {
                ContentUnavailableView {
                    Label("No matching tasks", systemImage: "line.3.horizontal.decrease")
                } description: {
                    Text(hiddenCount > 0
                         ? "Nothing has moved in the last 24 hours. Older tasks are in Customize."
                         : "Try another filter, or reset them to see every task.")
                } actions: {
                    Button("Customize") { showFilters = true }
                }
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            }
            ForEach(sections) { section in
                Section {
                    if isExpanded(section.id) {
                        ForEach(Array(section.sessions.enumerated()), id: \.element.id) { index, session in
                            TaskRow(session: session,
                                    isSelected: highlightId == session.id,
                                    isReplyTarget: replyTo == session.id,
                                    showsDivider: index < section.sessions.count - 1,
                                    onOpen: { detailCompletionNotificationID = nil; detailId = session.id },
                                    onReply: { replyTo = session.id })
                                .id(session.id)
                                .swipeActions(edge: .leading, allowsFullSwipe: true) { attentionSwipeButtons(session) }
                                .contextMenu { attentionMenu(session) }
                                .listRowInsets(.init(top: 0, leading: 0, bottom: 0, trailing: 0))
                                .listRowSeparator(.hidden)
                                .listRowBackground(Color.clear)
                        }
                    }
                } header: {
                    PhoneSectionHeader(title: section.title, count: section.sessions.count,
                                       expanded: expansion(section.id))
                        .padding(.horizontal, PhoneMetrics.gutter)
                        .padding(.top, 8).padding(.bottom, 5)
                        .background(CompanionPalette.bg)
                        .listRowInsets(.init(top: 0, leading: 0, bottom: 0, trailing: 0))
                }
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            }
            if hiddenCount > 0 {
                Button { filters.includeInactive = true } label: {
                    Label("Show \(hiddenCount) older", systemImage: "clock.arrow.circlepath")
                }
                .buttonStyle(PhoneButtonStyle(kind: .quiet, size: .small))
                .padding(.horizontal, PhoneMetrics.gutter).padding(.vertical, 14)
                .listRowInsets(.init(top: 0, leading: 0, bottom: 0, trailing: 0))
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            }
        }
        .listStyle(.plain)
        .listSectionSpacing(0)
        .environment(\.defaultMinListRowHeight, 0)
        .scrollContentBackground(.hidden)
        .background(CompanionPalette.bg)
        .scrollDismissesKeyboard(.interactively)
        .onReceive(clock) { now = $0 }
        .onChange(of: dashboard.focusedSessionId) { _, _ in focus(proxy) }
        .onChange(of: dashboard.state) { _, _ in focus(proxy) }
        .onChange(of: dashboard.groups) { _, _ in
            now = Date()
            if dashboard.focusedSessionId != nil { focus(proxy) }
            if let id = replyTo, !dashboard.allSessions.contains(where: { $0.id == id }) { replyTo = nil }
        }
        .safeAreaInset(edge: .top, spacing: 0) { toolbar }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                if voice.phase != .idle || voice.errorText != nil {
                    VoiceStrip(voice: voice)
                }
                StreamComposer(target: replyTarget,
                               macName: connection.pairing?.macName,
                               reachable: dashboard.state == .connected,
                               receipt: replyTarget.flatMap { dashboard.phoneActionState(for: $0) },
                               voice: voice,
                               clearTarget: { replyTo = nil },
                               newTask: { newTaskDraft = ""; showNewTask = true },
                               send: send(_:target:))
            }
            .background(CompanionPalette.bg)
        }
        .animation(.smooth, value: dashboard.groups)
        .animation(.smooth, value: replyTo)
        .toolbar(.hidden, for: .navigationBar)
        .tint(CompanionPalette.accent)
        .sheet(isPresented: $showFilters, onDismiss: {
            waitingForFilterDismiss = false
            focus(proxy)
        }) {
            NavigationStack {
                DashboardCustomizeSheet(selection: $filters, sessions: dashboard.allSessions)
            }
            .presentationDetents([.large])
        }
        .sheet(isPresented: $showQuota) {
            AccountQuotaView().environmentObject(dashboard).environmentObject(connection)
        }
        .sheet(isPresented: $showNewTask) { NewTaskSheet(dashboard: dashboard, initialPrompt: newTaskDraft) }
        .sheet(isPresented: $showSettings) {
            // A sheet doesn't inherit the presenter's environment objects, so
            // re-inject `voice` — Settings restarts a live session on change.
            SettingsView(connectionTest: settingsConnectionTest)
                .environmentObject(voice)
                .environmentObject(dashboard)
        }
        .sheet(isPresented: $voice.showConsent) { VoiceConsentSheet(voice: voice) }
        .sheet(item: Binding(get: { detailSession.map { DetailTarget(id: $0.id) } },
                             set: { detailId = $0?.id })) { target in
            if let session = dashboard.allSessions.first(where: { $0.id == target.id }) {
                let displayedCompletion = dashboard.completionRequest(for: session)
                SessionDetailSheet(session: session, completionNotificationID: detailCompletionNotificationID, onReply: { replyTo = session.id; detailId = nil })
                    .environmentObject(dashboard)
                    .safeAreaInset(edge: .bottom) {
                        if let status = dashboard.completionReadStatus(for: session) {
                            Text(status).font(CompanionType.font(12)).padding().frame(maxWidth: .infinity)
                                .background(.regularMaterial)
                        }
                    }
                    .task(id: displayedCompletion) {
                        if let id = detailCompletionNotificationID,
                           !dashboard.matchesCompletionNotification(id, sessionID: session.id) { return }
                        dashboard.acknowledge(session.id, displayedCompletion: displayedCompletion)
                    }
            }
        }
        .alert("This completion is no longer current", isPresented: $dashboard.completionLinkUnavailable) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("The task or paired Mac has changed. Open the current task to view its latest result. Nothing was marked read.")
        }
        .overlay(alignment: .bottom) {
            if let toast = dashboard.toast {
                Text(toast)
                    .font(CompanionType.font(13, .medium))
                    .foregroundStyle(CompanionPalette.bg3)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(CompanionPalette.ink, in: Capsule())
                    .padding(.bottom, 100)
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

    /// Glyph buttons floating over the page: the account's allowance on the
    /// left, what the list shows and how the phone behaves on the right.
    private var toolbar: some View {
        HStack(spacing: 10) {
            PhoneCircleButton("chart.bar") { showQuota = true }
                .accessibilityLabel("Account quota")
            Spacer(minLength: 0)
            PhoneCircleButton("line.3.horizontal.decrease",
                              tint: filters.isActive ? CompanionPalette.accent : CompanionPalette.ink) {
                showFilters = true
            }
            .accessibilityLabel("Customize")
            PhoneCircleButton("gearshape") { showSettings = true }
                .accessibilityLabel("Settings")
        }
        .padding(.horizontal, PhoneMetrics.gutter)
        .padding(.top, 6).padding(.bottom, 8)
        .background(CompanionPalette.bg)
    }

    /// The page title is the paired Mac: a dot for the link, its name, and a
    /// menu holding everything about the connection. Under it, one line about
    /// the whole snapshot — what the cat used to say.
    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
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
            Text(statusLine)
                .font(CompanionType.font(13))
                .foregroundStyle(CompanionPalette.ink2)
                .lineLimit(2)
            // The buddy's scope used to be the cat's subline; it is still the
            // one thing about a conversation worth a line before it starts.
            if companionEnabled, !dashboard.buddySessionIDs.isEmpty {
                Label("Voice scope: \(dashboard.buddySessionIDs.count) tasks", systemImage: "waveform")
                    .font(CompanionType.font(11))
                    .foregroundStyle(CompanionPalette.ink3)
            }
            if filters.isActive {
                Button { showFilters = true } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "line.3.horizontal.decrease")
                        Text(filters.summary).lineLimit(1)
                    }
                }
                .buttonStyle(PhoneButtonStyle(kind: .quiet, size: .small))
                .padding(.top, 6)
            }
        }
    }

    /// `All quiet · 2 working · 1 done`, over the current sessions of the whole
    /// snapshot (`SessionCurrency`) — the same numbers the island, the widget,
    /// the Watch and the Mac panel say. A filter narrows the list, never the
    /// line that says what is going on.
    private var statusLine: String {
        let summary = TaskPresentationSummary(currentIn: dashboard.allSessions, now: now)
        let rest = CompanionCopy.restLine(summary)
        return [CompanionCopy.moodLine(summary), rest.isEmpty ? nil : rest]
            .compactMap { $0 }.joined(separator: " · ")
    }

    private func isExpanded(_ id: String) -> Bool { !collapsed.contains(id) }

    private func expansion(_ id: String) -> Binding<Bool> {
        Binding(get: { isExpanded(id) },
                set: { expand in if expand { collapsed.remove(id) } else { collapsed.insert(id) } })
    }

    private struct DetailTarget: Identifiable { let id: String }

    /// What the composer's text does, decided by the message it replies to.
    private func send(_ text: String, target: AgentSession?) async -> Bool {
        guard let target else {
            newTaskDraft = text
            showNewTask = true
            return true
        }
        let result = await dashboard.answer(target.id, answer: text, expected: target)
        return result == .received
    }

    /// Scroll to and briefly highlight the session a deep link asked to open.
    /// No-ops (leaving the request pending) until that session is in the list, so
    /// a cold-start link still lands once the first snapshot arrives.
    private func focus(_ proxy: ScrollViewProxy) {
        guard !waitingForFilterDismiss, let id = dashboard.focusedSessionId else { return }
        if showFilters {
            waitingForFilterDismiss = true
            showFilters = false
            return // Resume from the filter sheet's onDismiss, retaining the exact deep link.
        }
        if let notificationID = dashboard.focusedCompletionNotificationID {
            guard dashboard.state == .connected else { return }
            let unbound = dashboard.allSessions.first { $0.id == id }?
                .isUnboundCompletionNotification(notificationID) == true
            guard unbound || dashboard.matchesCompletionNotification(notificationID, sessionID: id) else {
                dashboard.clearFocus()
                dashboard.completionLinkUnavailable = true
                return
            }
            detailCompletionNotificationID = notificationID
            detailId = id
            dashboard.clearFocus()
            return
        }
        guard dashboard.allSessions.contains(where: { $0.id == id }) else { return }
        detailCompletionNotificationID = nil
        detailId = id
        dashboard.clearFocus()
        if stream.contains(where: { $0.id == id }) {
            withAnimation(.smooth) { proxy.scrollTo(id, anchor: .center) }
        }
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
            .tint(CompanionPalette.status(.requiresInput))
        }
        if session.effectiveAttention != .muted {
            Button { dashboard.setAttention(session.id, .muted) } label: {
                Label(SessionAttention.muted.actionTitle, systemImage: SessionAttention.muted.symbol)
            }
            .tint(CompanionPalette.ink3)
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
        switch SessionActionSupport.resolve(for: target).intent {
        case .answer: self = .answer
        // The composer never resolves to stop — it carries no text — and a
        // stoppable session is a running one, whose composer is an instruction.
        case .steer, .stop: self = .instruction
        case .continue: self = .continuation
        }
    }

    var verb: LocalizedStringKey {
        switch self {
        case .answer: "Answer"
        case .instruction: "Send instruction"
        case .continuation: "Continue"
        case .newTask: "New task"
        }
    }

    var verbLabel: String {
        switch self {
        case .answer: String(localized: "Answer")
        case .instruction: String(localized: "Send instruction")
        case .continuation: String(localized: "Continue")
        case .newTask: String(localized: "New task")
        }
    }

    func placeholder(for target: AgentSession?) -> String {
        switch self {
        case .answer: String(localized: "Answer \(target?.displayTitle ?? "")…")
        case .instruction: String(localized: "Instruction for \(target?.displayTitle ?? "")…")
        case .continuation: String(localized: "Continue \(target?.displayTitle ?? "") with…")
        case .newTask: String(localized: "Plan, ask, build…")
        }
    }

    func unsupportedReason(for target: AgentSession?) -> String? {
        target.flatMap { SessionActionSupport.resolve(for: $0).unsupportedReason }
    }

    /// Said when sending works but does not land the way the verb reads — a
    /// Cursor turn cannot be interrupted, so a supplement waits for the turn to
    /// end. Shown under the field so nobody taps Send expecting otherwise.
    func note(for target: AgentSession?) -> String? {
        target.flatMap { SessionActionSupport.resolve(for: $0).note }
    }
}

/// One task as a row: a state dot, its title, the agent and project under it,
/// then `ACTIVITY — summary`; a pending approval or question is answered in
/// place. Rows sit on the page and are told apart by a hairline, not a card.
private struct TaskRow: View {
    let session: AgentSession
    let isSelected: Bool
    let isReplyTarget: Bool
    let showsDivider: Bool
    let onOpen: () -> Void
    let onReply: () -> Void
    @EnvironmentObject private var dashboard: DashboardStore

    private var state: TaskPresentationState { session.presentationState }
    private var canReply: Bool {
        guard session.agent != .grokBot else { return false }
        if session.pendingQuestion != nil { return SessionActionSupport.resolve(for: session).isAvailable }
        return session.agent == .codex && session.status != .needsResponse
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Button(action: onOpen) { headline }
                    .buttonStyle(.plain)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(accessibilityLabel)
                    .accessibilityHint("Open details")
                activity
                if let approval = session.pendingApproval { approvalBlock(approval) }
                if let question = session.pendingQuestion { questionBlock(question) }
                if let child = ToolActivity.childSummary(for: session) {
                    Text(child).font(CompanionType.font(11)).foregroundStyle(CompanionPalette.ink3)
                        .monospacedDigit().lineLimit(1)
                }
                if session.status == .needsResponse && session.pendingApproval == nil && session.pendingQuestion == nil {
                    Text(WaitHandling.resolve(for: session).message)
                        .font(CompanionType.font(12)).foregroundStyle(CompanionPalette.ink2)
                }
                if session.status == .needsResponse && dashboard.state != .connected {
                    Text("Connection to your Mac is unavailable. Reconnect to verify this request.")
                        .font(CompanionType.font(12)).foregroundStyle(CompanionPalette.ink2)
                }
                actions
            }
            .padding(.horizontal, PhoneMetrics.gutter)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected || isReplyTarget ? CompanionPalette.accent.opacity(0.08) : .clear)
            if showsDivider { PhoneDivider(leading: PhoneMetrics.gutter) }
        }
    }

    /// Title, state word, activity or summary, and the relative time, read as
    /// one element; the approve / deny / reply keys below stay separate.
    private var accessibilityLabel: String {
        let when = RelativeDateTimeFormatter().localizedString(for: session.updatedAt, relativeTo: Date())
        return [session.displayTitle, state.label,
                session.displaySummary ?? ToolActivity.label(for: session), when]
            .filter { !$0.isEmpty }.joined(separator: ", ")
    }

    private var headline: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle().fill(CompanionPalette.status(state))
                .frame(width: 9, height: 9)
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 3) {
                Text(session.displayTitle)
                    .font(CompanionType.font(15, .medium))
                    .tracking(CompanionType.tracking(15))
                    .foregroundStyle(CompanionPalette.ink)
                    .lineLimit(1)
                metaLine
            }
            Spacer(minLength: 6)
            Text(session.updatedAt, style: .relative)
                .font(CompanionType.font(11)).monospacedDigit()
                .foregroundStyle(CompanionPalette.ink3)
                .lineLimit(1)
        }
    }

    private var metaLine: some View {
        HStack(spacing: 5) {
            AgentAvatar(agent: session.agent, size: 14)
            Text(session.agent.shortName)
            if DashboardFilters.projectTitle(session.project) != session.displayTitle {
                Text("·")
                Text(DashboardFilters.projectTitle(session.project))
            }
            if let branch = session.branch {
                Text("·")
                Text(branch).font(CompanionType.mono(10)).lineLimit(1).truncationMode(.middle)
            }
            if session.effectiveAttention != .normal {
                Image(systemName: session.effectiveAttention == .followed ? "bell.badge.fill" : "bell.slash.fill")
                    .foregroundStyle(session.effectiveAttention == .followed
                                     ? CompanionPalette.status(.requiresInput) : CompanionPalette.ink3)
                    .accessibilityLabel(session.effectiveAttention.stateTitle)
            }
        }
        .font(CompanionType.font(11))
        .foregroundStyle(CompanionPalette.ink2)
        .lineLimit(1)
    }

    private var activity: some View {
        (Text(ToolActivity.label(for: session)).foregroundStyle(CompanionPalette.status(state))
         + Text("  ").foregroundStyle(CompanionPalette.ink3)
         + Text(session.displaySummary ?? "").foregroundStyle(CompanionPalette.ink2))
            .font(CompanionType.font(13))
            .lineLimit(3)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.leading, 19)
    }

    @ViewBuilder private func approvalKeys(_ approval: PendingApproval) -> some View {
        PhoneApproveButton(
            approve: { dashboard.decide(approval.id, .allow) },
            always: { dashboard.decide(approval.id, .alwaysAllow) },
            session: { dashboard.decide(approval.id, .allowSession) },
            allowsPersistentDecision: approval.canPersistDecision)
        Button("Deny") { dashboard.decide(approval.id, .deny) }
            .buttonStyle(PhoneButtonStyle(kind: .quiet))
    }

    @ViewBuilder private func approvalBlock(_ approval: PendingApproval) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("wants to \(CompanionCopy.requestVerb(approval)) · \(approval.tool)")
                .font(CompanionType.font(11, .medium)).textCase(.uppercase).kerning(0.4)
                .foregroundStyle(CompanionPalette.status(.requiresInput))
            ApprovalBody(approval: approval)
            if ApprovalEligibility.approval(for: session) == nil {
                Label(WaitHandling.resolve(for: session).message, systemImage: "keyboard")
                    .font(CompanionType.font(11)).foregroundStyle(CompanionPalette.ink2)
            } else {
                // At large type the two keys stack instead of clipping.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { approvalKeys(approval) }
                    VStack(alignment: .leading, spacing: 8) { approvalKeys(approval) }
                }
                .disabled(dashboard.phoneActionDisabled(for: session))
                if let result = dashboard.phoneActionState(for: session) {
                    Text(result.message).font(CompanionType.font(12)).foregroundStyle(CompanionPalette.ink2)
                }
                if let rule = approval.suggestedRule {
                    Text("Always allow adds \(rule) to Claude's own rules.")
                        .font(CompanionType.font(11)).foregroundStyle(CompanionPalette.ink3)
                }
            }
            if session.agent == .grok, let mode = approval.permissionMode, mode != "bypassPermissions" {
                Label {
                    Text("Grok will still ask in the terminal after Allow (permission mode: \(mode)). Set permission_mode = \"always-approve\" to approve from here.")
                } icon: {
                    Image(systemName: "terminal")
                }
                .font(CompanionType.font(11)).foregroundStyle(CompanionPalette.ink3)
            }
        }
        .padding(.leading, 19)
    }

    @ViewBuilder private func questionBlock(_ question: PendingQuestion) -> some View {
        Group {
            if WaitHandling.resolve(for: session) == .remoteAvailable {
                QuestionCardView(question: question, actionState: dashboard.phoneActionState(for: session)) { answers in
                    await dashboard.answer(session.id, answers: answers, expected: session)
                }
                .disabled(dashboard.phoneActionDisabled(for: session))
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text(question.prompt).font(CompanionType.font(14, .medium)).foregroundStyle(CompanionPalette.ink)
                    Label(WaitHandling.resolve(for: session).message, systemImage: "keyboard")
                        .font(CompanionType.font(11)).foregroundStyle(CompanionPalette.ink2)
                }
            }
        }
        .padding(.leading, 19)
    }

    @ViewBuilder private var actions: some View {
        if canReply || session.canJump {
            HStack(spacing: 8) {
                if canReply {
                    Button(action: onReply) { Label("Reply", systemImage: "arrowshape.turn.up.left") }
                        .buttonStyle(PhoneButtonStyle(
                            kind: isReplyTarget ? .primary(CompanionPalette.accent) : .quiet, size: .small))
                }
                if session.canJump {
                    Button(session.agent == .grokBot ? "Open Grok Bot" : session.jumpsToDesktopThread ? "Open thread" : "Jump") { dashboard.jump(session.id) }
                        .buttonStyle(PhoneButtonStyle(kind: .quiet, size: .small))
                }
            }
            .padding(.leading, 19)
        }
    }
}

/// The composer says whom the text goes to and what it means. With a reply
/// target the banner names both; without one the text is a new task. `+` starts
/// one from scratch, and the mic is the voice companion the cat used to host.
private struct StreamComposer: View {
    let target: AgentSession?
    let macName: String?
    let reachable: Bool
    let receipt: PhoneActionResult?
    @ObservedObject var voice: VoiceChat
    let clearTarget: () -> Void
    let newTask: () -> Void
    let send: (String, AgentSession?) async -> Bool
    @State private var sending = false
    @State private var draftTarget: AgentSession?
    @State private var draft = ""
    @FocusState private var focused: Bool
    @AppStorage("composer.micHintSeen") private var micHintSeen = false

    private var meaning: ReplyMeaning { ReplyMeaning(target: target) }
    private var unsupported: String? { meaning.unsupportedReason(for: target) }
    private var canSend: Bool {
        reachable && !sending && unsupported == nil
            && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    private var hasDraft: Bool { !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(spacing: 6) {
            if let target {
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 2).fill(CompanionPalette.status(target.presentationState))
                        .frame(width: 3)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(SessionActionSupport.targetCaption(macName: macName, session: target))
                            .font(CompanionType.font(10)).foregroundStyle(CompanionPalette.ink3)
                        Text("\(meaning.verbLabel) · \(target.displayTitle) · \(target.presentationState.label)")
                            .font(CompanionType.font(11, .medium)).foregroundStyle(CompanionPalette.ink2)
                        Text(unsupported ?? target.displaySummary ?? ToolActivity.label(for: target))
                            .font(CompanionType.font(12))
                            .foregroundStyle(unsupported == nil ? CompanionPalette.ink : CompanionPalette.status(.error))
                            .lineLimit(2)
                    }
                    Spacer(minLength: 0)
                    Button(action: clearTarget) {
                        Image(systemName: "xmark").font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(CompanionPalette.ink3)
                            .frame(width: 26, height: 26)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Cancel reply")
                }
                .padding(.horizontal, 10).padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .companionCard()
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            HStack(spacing: 8) {
                PhoneCircleButton("plus", size: 30, tint: CompanionPalette.ink2,
                                  ground: CompanionPalette.bg2, action: newTask)
                    .accessibilityLabel("New task")
                TextField(meaning.placeholder(for: target), text: $draft, axis: .vertical)
                    .font(CompanionType.font(14))
                    .lineLimit(1...4)
                    .focused($focused)
                    .padding(.vertical, 6)
                    .onSubmit(submit)
                // The mic is the voice companion's entry point (ADR-0017 §3):
                // always here, whether or not a draft is being typed.
                PhoneCircleButton(voiceGlyph, size: 30,
                                  tint: voice.phase == .idle ? CompanionPalette.ink2 : .onAccent,
                                  ground: voice.phase == .idle ? CompanionPalette.bg2 : CompanionPalette.accent) {
                    micHintSeen = true
                    voice.toggle()
                }
                .accessibilityLabel(voice.phase == .idle ? "Start voice conversation" : "End voice conversation")
                if hasDraft {
                    PhoneCircleButton("arrow.up", size: 30, tint: .onAccent,
                                      ground: canSend ? CompanionPalette.accent : CompanionPalette.ink3,
                                      action: submit)
                        .disabled(!canSend)
                        .accessibilityLabel(meaning.verbLabel)
                }
            }
            .padding(.horizontal, 6).padding(.vertical, 5)
            .background(CompanionPalette.bg3, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(CompanionPalette.line, lineWidth: CompanionType.hairline)
            }
            if sending {
                Text("Sending…")
                    .font(CompanionType.font(11)).foregroundStyle(CompanionPalette.ink2)
            } else if let receipt {
                Text(receipt.message)
                    .font(CompanionType.font(11))
                    .foregroundStyle(receiptColor(receipt))
            } else if !reachable {
                Text("Couldn't reach your Mac — not sent")
                    .font(CompanionType.font(11)).foregroundStyle(CompanionPalette.status(.error))
            } else if unsupported == nil, let note = meaning.note(for: target) {
                Text(note)
                    .font(CompanionType.font(11)).foregroundStyle(CompanionPalette.ink2)
            } else if !micHintSeen, !hasDraft, voice.phase == .idle, voice.errorText == nil {
                // Said once: the mic is explained the first time it appears,
                // then it is just the mic (ADR-0017 §3).
                Text("Tap the mic to talk to your sessions")
                    .font(CompanionType.font(11)).foregroundStyle(CompanionPalette.ink2)
            }
        }
        .padding(.horizontal, 12).padding(.top, 6).padding(.bottom, 8)
        .onChange(of: draft) { old, new in
            if old.isEmpty, !new.isEmpty { draftTarget = target }
        }
        .onChange(of: target?.id) { _, id in
            // An explicit Reply/cancel changes the intended destination; a new
            // wait in the same task does not retarget an existing draft.
            draftTarget = target
            if id != nil { focused = true }
        }
    }

    private var voiceGlyph: String {
        switch voice.phase {
        case .idle: return "mic"
        case .listening: return "mic.fill"
        case .speaking: return "waveform"
        case .connecting, .recovering, .thinking: return "ellipsis"
        }
    }

    private func receiptColor(_ receipt: PhoneActionResult) -> Color {
        switch receipt {
        case .received, .sending: CompanionPalette.ink2
        case .unconfirmed, .notPaired, .expired, .failed: CompanionPalette.status(.error)
        }
    }

    private func submit() {
        guard canSend else { return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let originalDraft = draft
        let originalTarget = draftTarget
        sending = true
        Task {
            if await send(text, originalTarget), draft == originalDraft,
               draftTarget?.id == originalTarget?.id,
               draftTarget?.pendingQuestion?.id == originalTarget?.pendingQuestion?.id,
               draftTarget?.statusSince == originalTarget?.statusSince {
                draft = ""; focused = false; draftTarget = nil
                clearTarget()
            }
            sending = false
        }
    }
}

/// Everything the row keeps behind it: the session's numbers, context, health,
/// how much it may interrupt you, and the ways to reach it.
private struct SessionDetailSheet: View {
    let session: AgentSession
    var completionNotificationID: String? = nil
    let onReply: () -> Void
    @EnvironmentObject private var dashboard: DashboardStore
    @Environment(\.dismiss) private var dismiss
    @AppStorage(VoiceSettings.companionEnabledKey) private var companionEnabled = false

    private var state: TaskPresentationState { session.presentationState }
    private var included: Bool { dashboard.buddySessionIDs.contains(session.id) }

    var body: some View {
        VStack(spacing: 0) {
            PhoneSheetHeader(title: String(localized: "Task")) { dismiss() }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 10) {
                        AgentAvatar(agent: session.agent, size: 36)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(session.displayTitle)
                                .font(CompanionType.font(22, .semibold))
                                .tracking(CompanionType.tracking(22))
                                .foregroundStyle(CompanionPalette.ink)
                            HStack(spacing: 6) {
                                Text(DashboardFilters.projectTitle(session.project))
                                AgentBadge(agent: session.agent)
                                if let branch = session.branch { Text(branch).font(CompanionType.mono(10)) }
                            }
                            .font(CompanionType.font(11)).foregroundStyle(CompanionPalette.ink2)
                        }
                    }
                    HStack(spacing: 6) {
                        Image(systemName: state.symbolName).font(.system(size: 10, weight: .semibold))
                        Text(state.label)
                    }
                    .font(CompanionType.font(12, .medium))
                    .foregroundStyle(CompanionPalette.status(state))
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(CompanionPalette.status(state).opacity(0.12),
                                in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    if session.completionNotice?.state == .pending {
                        Text("Preparing completion summary…")
                            .font(CompanionType.font(12)).foregroundStyle(CompanionPalette.ink2)
                    }
                    if let id = completionNotificationID,
                       !dashboard.matchesCompletionNotification(id, sessionID: session.id) {
                        if session.isUnboundCompletionNotification(id) {
                            Text("This notification does not identify a completion round. Review the current result before marking it read.")
                                .font(CompanionType.font(12)).foregroundStyle(CompanionPalette.ink2)
                            Button("Mark current result read") { dashboard.acknowledgeDisplayedCompletion(session) }
                                .buttonStyle(PhoneButtonStyle(kind: .quiet, size: .small))
                        } else {
                            Text("This task has moved on. You are viewing its current state, not the result from that notification.")
                                .font(CompanionType.font(12)).foregroundStyle(CompanionPalette.ink2)
                        }
                    }
                    if let summary = session.displaySummary, !summary.isEmpty {
                        Text(summary).font(CompanionType.font(14)).foregroundStyle(CompanionPalette.ink)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    RecentOutputCard(output: dashboard.recentOutputs[session.id])
                    metaCard
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Notifications").font(CompanionType.font(11, .medium)).textCase(.uppercase).kerning(0.5)
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
                            Button(session.agent == .grokBot ? "Open Grok Bot" : session.jumpsToDesktopThread ? "Open thread in ChatGPT" : "Jump to terminal") {
                                dashboard.jump(session.id)
                            }
                            .buttonStyle(PhoneButtonStyle(kind: .primary(CompanionPalette.accent)))
                        }
                        if session.agent != .grokBot {
                            Button { onReply() } label: { Label("Reply", systemImage: "arrowshape.turn.up.left") }
                                .buttonStyle(PhoneButtonStyle(kind: .quiet))
                        }
                        if companionEnabled {
                            Button { dashboard.toggleBuddy(session.id) } label: {
                                Label(included ? "In buddy's context" : "Add to buddy", systemImage: included ? "waveform.circle.fill" : "waveform.circle")
                            }
                            .buttonStyle(PhoneButtonStyle(kind: .quiet))
                        }
                    }
                }
                .padding(.horizontal, PhoneMetrics.gutter)
                .padding(.bottom, 24)
            }
        }
        .background(CompanionPalette.bg)
        .presentationDetents([.medium, .large])
        .tint(CompanionPalette.accent)
        .task { await dashboard.loadRecentOutput(session.id) }
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
private struct RecentOutputCard: View {
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
                Text(updatedAt, style: .relative).monospacedDigit()
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

    private func color(_ f: Double) -> Color {
        f > 0.9 ? CompanionPalette.status(.error)
            : f > 0.7 ? CompanionPalette.status(.requiresInput) : CompanionPalette.status(.thinking)
    }
    private func short(_ n: Int) -> String { n >= 1000 ? "\(n / 1000)k" : "\(n)" }
}

/// The page title as a menu about the paired Mac: a dot for the link state,
/// the Mac's name, and inside it the address, reconnect, copy and forget.
/// Tapping the name is the one place to manage the connection.
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
            HStack(spacing: 8) {
                Circle().fill(color).frame(width: 9, height: 9)
                Text(title)
                    .font(CompanionType.font(30, .semibold))
                    .tracking(CompanionType.tracking(30))
                    .foregroundStyle(CompanionPalette.ink)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 13, weight: .semibold))
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
                "No active tasks", systemImage: "moon.zzz",
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

/// Inline consent before the voice companion's first use: you tapped the mic, so
/// the ask is here, not buried in Settings. Continuing persists the opt-in; it
/// does not open the mic — the next tap starts the call.
private struct VoiceConsentSheet: View {
    @ObservedObject var voice: VoiceChat
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            PhoneSheetHeader(title: String(localized: "Voice companion")) { dismiss() }
            VStack(alignment: .leading, spacing: 16) {
                Text("Tap the mic to talk with your selected AI provider: Qwen (DashScope), OpenAI, or Gemini (Google).")
                    .foregroundStyle(CompanionPalette.ink2)
                Text("When you start a voice conversation, your microphone audio and selected session context (project names, agent type, status, and summaries) are sent directly to that provider using your own API key. The key stays in Keychain and nothing passes through a vibebuddy server.")
                    .foregroundStyle(CompanionPalette.ink2)
                Text("Continuing keeps the mic off until your next tap.")
                    .foregroundStyle(CompanionPalette.ink3)
                Spacer()
                Button { voice.enableCompanion(); dismiss() } label: {
                    Text("Continue")
                }
                .buttonStyle(PhoneButtonStyle(kind: .primary(CompanionPalette.accent), size: .wide))
            }
            .font(CompanionType.font(14))
            .padding(.horizontal, PhoneMetrics.gutter)
            .padding(.bottom, 20)
        }
        .background(CompanionPalette.bg)
        .presentationDetents([.medium])
    }
}
