import SwiftUI
import AppKit
import VibeBuddyKit
import VibeBuddyMacCore

/// The dashboard's library tabs, and the one programmatic way to land on one
/// of them from elsewhere. Settings › Plan & quota uses it to open the Usage
/// page rather than repeat its readings (ADR-0017 §6). `@Published` replays
/// the current value to a new subscriber, so a request made before the
/// dashboard window has ever been built still reaches the view once it is.
@MainActor
final class DashboardRoute: ObservableObject {
    enum Library: String { case live, history, favorites, usage }

    static let shared = DashboardRoute()
    @Published fileprivate var requested: Library?

    static func open(_ library: Library) {
        shared.requested = library
        NotificationCenter.default.post(name: .openDashboard, object: nil)
    }
}

/// Project navigation, the filtered session list, and the existing live detail
/// surface. These filters never alter the shared snapshot or Buddy scope.
struct DashboardView: View {
    @ObservedObject var model: MenuBarModel
    @State private var statusFilter: TaskPresentationState? = nil
    @State private var projectScope: DashboardSessionList.ProjectScope = .all
    @State private var query: String = ""
    @State private var showNewTask = false
    @State private var libraryScope = "live"
    /// History and Favorites filter by project path; the sidebar owns the
    /// choice so both libraries share one project list.
    @State private var historyProject: String?
    @StateObject private var history = HistoryLibraryModel()
    // Demo instance pre-selects the approval session so the detail pane (diff +
    // Approve/Deny) is shown for screenshots; nil in normal use.
    @State private var selection: String? =
        ProcessInfo.processInfo.environment["VIBEBUDDY_DEMO"] == "1" ? "demo-edit" : nil
    @FocusState private var searchFocused: Bool
    @AppStorage(VoiceSettings.companionEnabledKey) private var companionEnabled = false

    private var projection: DashboardSessionList {
        DashboardSessionList(model.sessions, project: projectScope, status: statusFilter,
                             query: query, selection: selection)
    }
    private var filtered: [AgentSession] { projection.visible }
    private var selectedSession: AgentSession? { projection.selected }

    private func projectTitle(_ scope: DashboardSessionList.ProjectScope) -> String {
        DashboardSidebar.title(scope)
    }

    /// The search field lives in the live and history list heads; Usage has
    /// none, so searching from there lands on Current tasks.
    private func focusSearch() {
        if libraryScope == "usage" { libraryScope = "live" }
        searchFocused = true
    }

    /// History's projects with a conversation count each, for the sidebar.
    private var historyProjects: [(path: String, count: Int)] {
        let counts = Dictionary(grouping: history.snapshot.sessions, by: \.projectPath).mapValues(\.count)
        return counts.keys.sorted().map { (path: $0, count: counts[$0] ?? 0) }
    }

    var body: some View {
        HStack(spacing: 0) {
            DashboardSidebar(model: model, voice: model.voiceChat, library: $libraryScope,
                             projectScope: $projectScope, historyProject: $historyProject,
                             liveProjects: projection.projects, historyProjects: historyProjects,
                             onNewTask: { showNewTask = true },
                             onSearch: focusSearch)
            Rectangle().fill(MacTheme.line).frame(width: CompanionType.hairline)
            Group {
                if libraryScope == "live" {
                    HSplitView {
                        sessionsColumn
                        detailColumn
                    }
                } else if libraryScope == "usage" {
                    UsageWorkbenchView(model: model)
                } else {
                    HistoryWorkbenchView(history: history, model: model, query: $query,
                                         favoritesOnly: libraryScope == "favorites",
                                         project: $historyProject, searchFocused: $searchFocused)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(MacTheme.bg)
        .onReceive(DashboardRoute.shared.$requested) { library in
            guard let library else { return }
            libraryScope = library.rawValue
            // Clear on the next turn so the request is consumed once and the
            // publisher is not re-entered from inside its own delivery.
            DispatchQueue.main.async { DashboardRoute.shared.requested = nil }
        }
        .sheet(isPresented: $showNewTask) { NewTaskSheet(model: model) }
        .onAppear {
            // `VIBEBUDDY_DEMO_PAGE=dashboard/<live|history|favorites|usage|newtask>`
            // lands on that library, or opens New task, for screenshots and QA.
            guard let page = ProcessInfo.processInfo.environment["VIBEBUDDY_DEMO_PAGE"],
                  page.hasPrefix("dashboard/") else { return }
            let target = String(page.dropFirst("dashboard/".count))
            if target == "newtask" { showNewTask = true } else if let library = DashboardRoute.Library(rawValue: target) {
                libraryScope = library.rawValue
            }
        }
        .background {
            Group {
                // ⌘N opens New task; the sheet itself explains when no agent
                // can start yet, so the entry is never disabled.
                Button("") { showNewTask = true }.keyboardShortcut("n", modifiers: .command)
                Button("") { statusFilter = .error }.keyboardShortcut("1", modifiers: .command)
                Button("") { statusFilter = .requiresInput }.keyboardShortcut("2", modifiers: .command)
                Button("") { statusFilter = .thinking }.keyboardShortcut("3", modifiers: .command)
                Button("") { statusFilter = .completeUnread }.keyboardShortcut("4", modifiers: .command)
                Button("") { statusFilter = .idle }.keyboardShortcut("5", modifiers: .command)
                Button("") { statusFilter = nil }.keyboardShortcut("0", modifiers: .command)
                // ⌘F focuses the search field, leaving Usage first if needed.
                Button("", action: focusSearch).keyboardShortcut("f", modifiers: .command)
                // ⏎ jumps to the selected session's terminal. Ignored while typing in
                // search so it doesn't shadow the field's own Return.
                Button("") {
                    // Text editors (including detail composers/questions) own
                    // Return while editing; a selected row must not steal it.
                    if libraryScope == "live", !searchFocused, !(NSApp.keyWindow?.firstResponder is NSTextView),
                       let s = selectedSession { model.jump(s) }
                }
                    .keyboardShortcut(.return, modifiers: [])
            }
            .opacity(0)
        }
        .onChange(of: selection) { _, id in
            if let id, filtered.contains(where: { $0.id == id }) { model.acknowledge(id) }
        }
        .onChange(of: filtered.map(\.id)) { _, ids in
            if let selection, !ids.contains(selection) { self.selection = nil }
        }
    }

    /// The list column's head, as Cursor lays out a list page: the scope as
    /// the title, the search field, then a row of filter chips. ⌘1–5 and ⌘0
    /// still drive the same filter.
    private var sessionsColumn: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text(projectTitle(projectScope)).font(MacTheme.font(13, .semibold)).foregroundStyle(MacTheme.ink)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 8)
                    Text(filtered.count == 1 ? String(localized: "1 session") : String(localized: "\(filtered.count) sessions"))
                        .font(MacTheme.mono(10)).foregroundStyle(MacTheme.ink3)
                }
                SearchPill(query: $query, focused: $searchFocused)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        FilterChip(title: "All", selected: statusFilter == nil) { statusFilter = nil }
                        ForEach([TaskPresentationState.requiresInput, .error, .thinking, .completeUnread, .idle], id: \.self) { state in
                            FilterChip(title: Self.chipTitle(state), selected: statusFilter == state) { statusFilter = state }
                        }
                        if projectScope != .all || !query.isEmpty {
                            Button("Reset") {
                                projectScope = .all
                                statusFilter = nil
                                query = ""
                            }
                            .buttonStyle(.plain).font(MacTheme.font(10.5)).foregroundStyle(MacTheme.ink3)
                        }
                    }
                }
                .accessibilityLabel("Filter sessions by state")
            }
            .padding(.horizontal, 12).padding(.top, 12)
            ScrollView {
                LazyVStack(spacing: 8) {
                    if filtered.isEmpty {
                        QuietEmptyState(title: model.sessions.isEmpty ? "No sessions reporting" : "No matching sessions",
                                        message: model.sessions.isEmpty
                                            ? "Start a Claude Code or Codex turn. If nothing appears, repair hooks in Settings."
                                            : "Clear a filter or try another search.",
                                        systemName: "waveform.path.ecg")
                            .padding(.top, 40)
                    } else {
                        ForEach(filtered) { session in
                            SummaryRow(session: session, isSelected: selection == session.id,
                                       included: model.buddySessionIDs.contains(session.id), showInclude: companionEnabled,
                                       onSelect: { selection = session.id },
                                       onToggleInclude: { model.toggleBuddy(session.id) })
                                .contextMenu { AttentionPicker(session: session, model: model, style: .menu) }
                        }
                    }
                }
                .padding(.horizontal, 12).padding(.bottom, 12)
            }
        }
        .frame(minWidth: 240, idealWidth: 300, maxWidth: 380, maxHeight: .infinity)
    }

    /// The chips use the menu panel's group words (Needs you / Working / Done),
    /// not the long state labels, so six of them fit on one line.
    static func chipTitle(_ state: TaskPresentationState) -> LocalizedStringKey {
        switch state {
        case .requiresInput: "Needs you"
        case .error: "Errors"
        case .thinking: "Working"
        case .completeUnread: "Done"
        case .idle: "Idle"
        case .unassigned: "Unassigned"
        }
    }

    @ViewBuilder private var detailColumn: some View {
        if let s = selectedSession {
            ScrollView {
                VStack(spacing: 0) {
                    DetailCard(session: s, model: model)
                    Divider()
                    RecentOutputPane(session: s, model: model)
                }
                .id(s.id)
                .companionCard(radius: MacTheme.panelRadius)
                .padding(12)
            }
            .frame(minWidth: 340, idealWidth: 380, maxWidth: .infinity)
        } else {
            QuietEmptyState(title: "Select a session", message: "Pick a task on the left to see its details.")
                .frame(minWidth: 340, idealWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
        }
    }

}

struct SearchPill: View {
    @Binding var query: String
    var focused: FocusState<Bool>.Binding
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .bold)).foregroundStyle(MacTheme.ink3)
            TextField("Search sessions", text: $query)
                .textFieldStyle(.plain)
                .font(MacTheme.font(12, .semibold))
                .focused(focused)
            if query.isEmpty {
                Text("⌘F").font(MacTheme.mono(10)).foregroundStyle(MacTheme.ink3)
            } else {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(MacTheme.ink3) }
                    .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10).frame(maxWidth: .infinity).frame(height: 28)
        .companionCard(radius: 14)
    }
}

/// A selectable task and an independent Buddy-scope control. Toggling Buddy
/// must not implicitly select or acknowledge the row.
private struct SummaryRow: View {
    let session: AgentSession
    var isSelected = false
    var included = false
    var showInclude = false
    var onSelect: () -> Void
    var onToggleInclude: () -> Void

    private var state: TaskPresentationState { session.presentationState }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Button(action: onSelect) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .top, spacing: 8) {
                        StateGlyph(state: state, size: 18)
                        Text(session.displayTitle).font(MacTheme.font(13, .medium))
                            .foregroundStyle(MacTheme.ink)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    HStack(spacing: 6) {
                        AgentBadge(agent: session.agent)
                        Spacer(minLength: 0)
                        if let glyph = session.effectiveAttention.rowGlyph {
                            Image(systemName: glyph).help(session.effectiveAttention.title)
                        }
                        Text(session.updatedAt, style: .relative).monospacedDigit()
                    }
                    .font(MacTheme.font(10)).foregroundStyle(MacTheme.ink2)
                    Text(LocalizedStringKey(state.label))
                        .font(MacTheme.font(11, .semibold)).foregroundStyle(MacTheme.status(state))
                    if session.isStuck {
                        Label("Stuck", systemImage: "exclamationmark.triangle.fill")
                            .font(MacTheme.font(10)).foregroundStyle(MacTheme.status(.error))
                    }
                    if let summary = session.summary, !summary.isEmpty {
                        Text(summary).font(MacTheme.font(11)).foregroundStyle(MacTheme.ink2)
                            .lineLimit(2).help(summary)
                    }
                    Text("Activity: \(ToolActivity.label(for: session))")
                    Text(session.project.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                         ? String(localized: "Unknown project (unassigned)") : session.project)
                        .fixedSize(horizontal: false, vertical: true)
                    if let branch = session.branch { Text(branch).font(MacTheme.mono(10)).help(branch) }
                    if let cost = session.estimatedCostUSD {
                        Text("\(session.costUSD == nil ? "≈ " : "")$\(cost, specifier: "%.2f")").monospacedDigit()
                    }
                    if let effort = session.effort { Text("effort \(effort)") }
                    if let pr = session.prNumber { Text("PR #\(pr)") }
                    if let worktree = session.worktree { Text(worktree).font(MacTheme.mono(10)).help(worktree) }
                    if let observation = session.observationDescription { Text(observation) }
                    if let child = ToolActivity.childSummary(for: session) { Text(child) }
                }
                .font(MacTheme.font(10)).foregroundStyle(MacTheme.ink2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            if showInclude {
                Button(action: onToggleInclude) {
                    Image(systemName: included ? "waveform.circle.fill" : "waveform.circle")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(included ? MacTheme.accent : MacTheme.ink2)
                .accessibilityLabel(included ? "Remove from the buddy's context" : "Add to the buddy's context")
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .companionCard(isSelected ? MacTheme.bg2 : MacTheme.bg3)
        .overlay {
            if isSelected {
                RoundedRectangle(cornerRadius: MacTheme.cardRadius, style: .continuous)
                    .strokeBorder(MacTheme.ink.opacity(0.28), lineWidth: CompanionType.hairline)
                    .allowsHitTesting(false)
            }
        }
    }
}

/// The detail card: a request card while an approval is pending, otherwise the
/// session's summary and its controls.
private struct DetailCard: View {
    let session: AgentSession
    @ObservedObject var model: MenuBarModel
    @State private var showTranscript = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(session.displayTitle).font(MacTheme.font(20, .semibold)).foregroundStyle(MacTheme.ink)
                .fixedSize(horizontal: false, vertical: true)
            if session.name != nil {
                Text(session.project).font(MacTheme.font(12, .bold)).foregroundStyle(MacTheme.ink3)
            }
            HStack(spacing: 6) {
                Image(systemName: session.presentationState.symbolName).font(.system(size: 10, weight: .bold))
                Text(session.statusLabel)
            }
            .font(MacTheme.font(12, .heavy))
            .foregroundStyle(MacTheme.status(session.presentationState))
            .padding(.horizontal, 12).padding(.vertical, 4)
            .background(MacTheme.status(session.presentationState).opacity(0.14), in: Capsule())

            if session.status == .needsResponse && session.pendingApproval == nil && session.pendingQuestion == nil {
                Text(WaitHandling.resolve(for: session).message).font(MacTheme.font(10))
            }
            if let approval = session.pendingApproval {
                RequestCard(session: session, approval: approval, model: model)
            } else {
                if let question = session.pendingQuestion {
                    if WaitHandling.resolve(for: session) == .remoteAvailable {
                        QuestionCardView(question: question) { answers in
                            model.answer(session.id, answers: answers)
                        }
                    } else {
                        Text(question.prompt).font(MacTheme.font(14, .heavy)).foregroundStyle(MacTheme.ink)
                            .fixedSize(horizontal: false, vertical: true)
                        Label(WaitHandling.resolve(for: session).message, systemImage: "keyboard")
                            .font(MacTheme.font(11, .semibold)).foregroundStyle(MacTheme.ink2)
                    }
                } else if let s = session.summary, !s.isEmpty {
                    Text(s).font(MacTheme.font(14, .semibold)).foregroundStyle(MacTheme.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if session.agent == .codex && session.status != .needsResponse && SessionActionSupport.resolve(for: session).isAvailable {
                    // Free text for a Codex thread: joins the running turn or
                    // opens a new one, through the app-server daemon.
                    InstructionComposer(placeholder: session.status == .done
                                        ? "Start a new turn…" : "Add to the current turn…") { text in
                        model.answer(session.id, answers: [:], text: text)
                    }
                }
                if let feedback = model.answerFeedback[session.id] {
                    Label(feedback, systemImage: "exclamationmark.bubble")
                        .font(MacTheme.font(11, .semibold)).foregroundStyle(MacTheme.ink2)
                }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { detailActions }
                    VStack(alignment: .leading, spacing: 8) { detailActions }
                }
            }
            // What the last jump actually achieved — focused the pane, only
            // raised the app, or found nothing to raise. Same wording as the
            // glance rows.
            if let outcome = model.jumpFeedback[session.id] {
                Label(outcome.macMessage(for: session), systemImage: "arrow.uturn.forward")
                    .font(MacTheme.font(11, .semibold)).foregroundStyle(MacTheme.ink2)
                    .contentTransition(.opacity)
            }
            if session.pendingApproval != nil {
                Button { showTranscript = true } label: { Label("Recent output", systemImage: "text.alignleft") }
                    .buttonStyle(PillButtonStyle(kind: .soft, size: .small))
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Notifications").font(MacTheme.font(11, .heavy)).foregroundStyle(MacTheme.ink3)
                    .textCase(.uppercase).kerning(0.6)
                AttentionPicker(session: session, model: model, style: .chips)
                Text(session.attentionOverride == nil
                     ? String(localized: "Automatic: \(session.effectiveAttention.title.lowercased()) — followed while you're driving it, normal otherwise.")
                     : session.effectiveAttention.explanation)
                    .font(MacTheme.font(11, .semibold)).foregroundStyle(MacTheme.ink3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 6) {
                if let m = session.model { Label(m, systemImage: "cpu") }
                if let observation = session.observationDescription {
                    Text("·"); Text(observation)
                }
            }
            .font(MacTheme.font(11, .semibold)).foregroundStyle(MacTheme.ink3)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.smooth(duration: 0.18), value: model.jumpFeedback)
        .sheet(isPresented: $showTranscript) {
            TranscriptSheet(session: session, model: model)
        }
    }
    @ViewBuilder private var detailActions: some View {
        Button(session.agent == .grokBot ? "Open Grok Bot" : session.jumpsToDesktopThread ? "Open thread in ChatGPT" : "Jump to terminal") { model.jump(session) }
            .buttonStyle(PillButtonStyle(kind: .filled(MacTheme.accent)))
        Button { showTranscript = true } label: { Label("Recent output", systemImage: "text.alignleft") }
            .buttonStyle(PillButtonStyle(kind: .soft))
    }

}

/// Round 4, detail pane: the request as a card you can judge before answering —
/// who asks, what for, the diff or command, then Approve ▾ / Deny / Jump.
private struct RequestCard: View {
    let session: AgentSession
    let approval: PendingApproval
    @ObservedObject var model: MenuBarModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                AgentAvatar(agent: session.agent)
                VStack(alignment: .leading, spacing: 1) {
                    (Text(session.project).fontWeight(.black) + Text(" wants to \(MacSummaryCopy.requestVerb(approval))"))
                        .font(MacTheme.font(13, .semibold)).foregroundStyle(MacTheme.ink)
                    Text([approval.tool, session.summary].compactMap { $0 }.joined(separator: " · "))
                        .font(MacTheme.font(11, .semibold)).foregroundStyle(MacTheme.ink3).lineLimit(1)
                }
            }
            ApprovalBody(approval: approval)
            if ApprovalEligibility.approval(for: session) == nil {
                // Capability does not establish whether the person is present.
                Label(WaitHandling.resolve(for: session).message, systemImage: "keyboard")
                    .font(MacTheme.font(11, .semibold)).foregroundStyle(MacTheme.ink2)
                if session.canJump {
                Button(session.agent == .grokBot ? "Open Grok Bot" : session.jumpsToDesktopThread ? "Open thread" : "Jump ⏎") { model.jump(session) }
                    .buttonStyle(PillButtonStyle(kind: .filled(MacTheme.accent)))
                }
            } else {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { approvalActions }
                VStack(alignment: .leading, spacing: 8) { approvalActions }
            }
            if let rule = approval.suggestedRule {
                Text("Always allow adds \(rule) to Claude's own permission rules — the same rule the terminal dialog offers.")
                    .font(MacTheme.font(11, .semibold)).foregroundStyle(MacTheme.ink3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            }
            if session.agent == .grok, let mode = approval.permissionMode, mode != "bypassPermissions" {
                Label {
                    Text("Grok will still ask in the terminal after Allow (permission mode: \(mode)). Set permission_mode = \"always-approve\" to approve from here.")
                } icon: {
                    Image(systemName: "terminal")
                }
                .font(MacTheme.font(11, .semibold)).foregroundStyle(MacTheme.ink2)
            }
        }
    }

    @ViewBuilder private var approvalActions: some View {
        SplitApproveButton(
            approve: { model.decide(approval.id, .allow) },
            always: { model.decide(approval.id, .alwaysAllow) },
            session: { model.decide(approval.id, .allowSession) },
            allowsPersistentDecision: approval.canPersistDecision)
            .background { Button("") { model.decide(approval.id, .allow) }.keyboardShortcut("a", modifiers: []).opacity(0) }
        Button("Deny") { model.decide(approval.id, .deny) }
            .buttonStyle(PillButtonStyle(kind: .ghost))
            .keyboardShortcut("d", modifiers: [])
        Button(session.agent == .grokBot ? "Open Grok Bot" : session.jumpsToDesktopThread ? "Open thread" : "Jump ⏎") { model.jump(session) }
            .buttonStyle(PillButtonStyle(kind: .ghost))
    }

}

struct VoiceConsentSheet: View {
    @ObservedObject var voice: VoiceChat
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Voice companion", systemImage: "waveform").font(MacTheme.font(13, .semibold))
            Text("Tap the buddy to talk — it knows your sessions and can approve / answer for you. Pick the provider whose key you've filled in below. Switching applies instantly if the buddy is already listening.")
                .font(MacTheme.font(12)).foregroundStyle(MacTheme.ink2)
                .fixedSize(horizontal: false, vertical: true)
            Text("Enabling opens the mic on the next tap and shares your live sessions with your selected provider, using your own key.")
                .font(MacTheme.font(10)).foregroundStyle(MacTheme.ink2)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(PillButtonStyle(kind: .ghost, size: .small))
                Button("Enable") { voice.enableCompanion(); dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(PillButtonStyle(kind: .filled(MacTheme.accent), size: .small))
            }
        }
        .padding(20).frame(width: 380)
    }
}

private struct TranscriptSheet: View {
    let session: AgentSession
    @ObservedObject var model: MenuBarModel
    @Environment(\.dismiss) private var dismiss
    @State private var output: RecentOutput?
    @State private var loaded = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Recent output").font(MacTheme.font(13, .semibold))
                    Text(session.project).font(MacTheme.font(10)).foregroundStyle(MacTheme.ink2)
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding()
            Divider()
            content
        }
        .frame(minWidth: 460, minHeight: 360)
        .task {
            output = await model.recentOutput(for: session.id)
            loaded = true
        }
    }

    @ViewBuilder
    private var content: some View {
        if !loaded {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let output, output.entries.isEmpty {
            QuietEmptyState(title: "No recent output",
                            message: output.statusLine.isEmpty
                                ? "This session hasn't reported a transcript yet." : LocalizedStringKey(output.statusLine),
                            systemName: "text.alignleft")
        } else if let output {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 6) {
                        Text(output.sourceLabel)
                        if let updatedAt = output.updatedAt {
                            Text("·")
                            Text(updatedAt, style: .relative).monospacedDigit()
                        }
                    }
                    .font(MacTheme.font(10, .semibold))
                    .foregroundStyle(MacTheme.ink2)
                    if !output.statusLine.isEmpty {
                        Text(output.statusLine).font(MacTheme.font(10)).foregroundStyle(MacTheme.ink2)
                    }
                    ForEach(Array(output.entries.enumerated()), id: \.offset) { _, entry in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(entry.role == "assistant" ? "Assistant" : "You")
                                .font(MacTheme.font(10, .semibold))
                                .foregroundStyle(entry.role == "assistant" ? Color.blue : MacTheme.ink2)
                            Text(entry.text)
                                .font(MacTheme.font(12))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .padding()
            }
        }
    }
}

/// Bounded live output in the main reading pane; never described as full history.
private struct RecentOutputPane: View {
    let session: AgentSession
    @ObservedObject var model: MenuBarModel
    @State private var output: RecentOutput?
    @State private var loading = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Recent output").font(MacTheme.font(13, .semibold))
                Spacer()
                Button("Refresh") { Task { await reload() } }
                    .buttonStyle(PillButtonStyle(kind: .ghost, size: .small)).disabled(loading)
            }
            if let output {
                Text(output.sourceLabel).font(MacTheme.font(10)).foregroundStyle(MacTheme.ink2)
                if !output.statusLine.isEmpty {
                    Text(output.statusLine).font(MacTheme.font(10)).foregroundStyle(MacTheme.ink2)
                }
                Text("A limited recent excerpt. Open History to read indexed local conversations.")
                    .font(MacTheme.font(10)).foregroundStyle(MacTheme.ink2)
                if output.entries.isEmpty {
                    Text("No recent output is available from this source.")
                        .foregroundStyle(MacTheme.ink2)
                }
                ForEach(Array(output.entries.enumerated()), id: \.offset) { _, entry in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(entry.role == "assistant" ? "Assistant" : "You")
                            .font(MacTheme.font(10, .semibold)).foregroundStyle(MacTheme.ink2)
                        Text(entry.text).font(MacTheme.font(13)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            } else { ProgressView() }
        }
        .padding(20)
        .task(id: session.id) { await reload() }
    }

    private func reload() async {
        loading = true
        output = await model.recentOutput(for: session.id)
        loading = false
    }
}

/// One line of free text for a session, sent with ⌘↩ or the button.
struct InstructionComposer: View {
    let placeholder: String
    let send: (String) -> Void
    @State private var draft = ""

    var body: some View {
        HStack(spacing: 8) {
            TextField(placeholder, text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(MacTheme.font(13, .semibold))
                .lineLimit(1...4)
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(MacTheme.bg2, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .onSubmit(submit)
            Button("Send", action: submit)
                .buttonStyle(PillButtonStyle(kind: .filled(MacTheme.accent)))
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private func submit() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        send(text)
        draft = ""
    }
}

/// The one control for how much a session may interrupt you, in two shapes:
/// a row of filter chips in the detail pane (the list head's chips, so the
/// card carries no system segmented control) and radio items in a row's
/// context menu. `nil` is "automatic" — the daemon's own reading of recent
/// interaction.
private struct AttentionPicker: View {
    enum Style { case chips, menu }
    let session: AgentSession
    @ObservedObject var model: MenuBarModel
    let style: Style

    private var selection: Binding<SessionAttention?> {
        Binding(get: { session.attentionOverride },
                set: { model.setAttention(session.id, $0) })
    }

    var body: some View {
        switch style {
        case .chips: chips
        case .menu: picker.pickerStyle(.inline)
        }
    }

    private var chips: some View {
        HStack(spacing: 6) {
            FilterChip(title: "Auto", selected: session.attentionOverride == nil) { selection.wrappedValue = nil }
            ForEach(SessionAttention.allCases, id: \.self) { level in
                FilterChip(title: LocalizedStringKey(level.titleKey), selected: session.attentionOverride == level) {
                    selection.wrappedValue = level
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Notifications")
    }

    private var picker: some View {
        Picker("Notifications", selection: selection) {
            Text("Automatic (\(autoLevel.title.lowercased()))").tag(SessionAttention?.none)
            ForEach(SessionAttention.allCases, id: \.self) { level in
                Label(level.title, systemImage: level.symbol).tag(SessionAttention?.some(level))
            }
        }
        .labelsHidden()
    }

    /// What automatic would give right now: the effective level while no
    /// override is set, else the daemon's `attention` still reflects the
    /// override, so fall back to `normal` as the honest default.
    private var autoLevel: SessionAttention {
        session.attentionOverride == nil ? session.effectiveAttention : .normal
    }
}

extension SessionAttention {
    /// The English key; `title` is its localized form.
    var titleKey: String {
        switch self {
        case .followed: "Followed"
        case .normal: "Normal"
        case .muted: "Muted"
        }
    }
    var title: String { String(localized: String.LocalizationValue(titleKey)) }
    var symbol: String {
        switch self {
        case .followed: "bell.badge"
        case .normal: "bell"
        case .muted: "bell.slash"
        }
    }
    /// A glyph on the row only when the session is not at the default.
    var rowGlyph: String? { self == .normal ? nil : symbol }
    var explanation: String {
        switch self {
        case .followed: String(localized: "Everything about this session interrupts you.")
        case .normal: String(localized: "Only approvals and failures interrupt; the rest waits in Notification Center.")
        case .muted: String(localized: "Approvals show silently; nothing else interrupts.")
        }
    }
}
