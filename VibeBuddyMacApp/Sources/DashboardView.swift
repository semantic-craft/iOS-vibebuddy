import SwiftUI
import VibeBuddyKit
import VibeBuddyMacCore

/// The dashboard window, Companion style (docs/design/mac-companion-redesign.md):
/// a top bar with the cat and its speech bubble, sessions grouped by state
/// (Needs you / Working / Done) and one detail card on the right.
struct DashboardView: View {
    @ObservedObject var model: MenuBarModel
    @Environment(\.openSettings) private var openSettings
    @State private var statusFilter: TaskPresentationState? = nil
    @State private var query: String = ""
    @State private var showNewTask = false
    // Demo instance pre-selects the approval session so the detail pane (diff +
    // Approve/Deny) is shown for screenshots; nil in normal use.
    @State private var selection: String? =
        ProcessInfo.processInfo.environment["VIBEBUDDY_DEMO"] == "1" ? "demo-edit" : nil
    @FocusState private var searchFocused: Bool
    @AppStorage(VoiceSettings.companionEnabledKey) private var companionEnabled = false

    private var filtered: [AgentSession] {
        SessionFilter.apply(model.sessions, status: nil, agent: nil, query: query)
            .filter { statusFilter == nil || $0.presentationState == statusFilter }
            .sorted {
                $0.presentationState.attentionRank != $1.presentationState.attentionRank
                    ? $0.presentationState.attentionRank < $1.presentationState.attentionRank
                    : $0.updatedAt > $1.updatedAt
            }
    }
    private var groups: StateGroups { StateGroups(filtered) }
    private var selectedSession: AgentSession? { model.sessions.first { $0.id == selection } }

    var body: some View {
        VStack(spacing: 0) {
            MacBuddyBar(model: model, voice: model.voiceChat, query: $query, searchFocused: $searchFocused)
            HStack(alignment: .top, spacing: 0) {
                groupsColumn
                detailColumn
            }
        }
        .background(MacTheme.bg)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showNewTask = true } label: { Image(systemName: "plus.bubble") }
                    .help("Start a new task in a directory a session has run in")
                    .disabled(model.recentDirectories.isEmpty || model.dispatchAgents.isEmpty)
            }
            ToolbarItem(placement: .primaryAction) {
                Button { openSettings() } label: { Image(systemName: "gearshape") }
                    .help("Settings")
            }
        }
        .sheet(isPresented: $showNewTask) { NewTaskSheet(model: model) }
        .background {
            Group {
                Button("") { statusFilter = .error }.keyboardShortcut("1", modifiers: .command)
                Button("") { statusFilter = .requiresInput }.keyboardShortcut("2", modifiers: .command)
                Button("") { statusFilter = .thinking }.keyboardShortcut("3", modifiers: .command)
                Button("") { statusFilter = .completeUnread }.keyboardShortcut("4", modifiers: .command)
                Button("") { statusFilter = .idle }.keyboardShortcut("5", modifiers: .command)
                Button("") { statusFilter = nil }.keyboardShortcut("0", modifiers: .command)
                // ⌘F focuses the sessions search field.
                Button("") { searchFocused = true }.keyboardShortcut("f", modifiers: .command)
                // ⏎ jumps to the selected session's terminal. Ignored while typing in
                // search so it doesn't shadow the field's own Return.
                Button("") { if !searchFocused, let s = selectedSession { model.jump(s) } }
                    .keyboardShortcut(.return, modifiers: [])
            }
            .opacity(0)
        }
        .onAppear { AppActivationPolicy.activateFront() }
        .onChange(of: selection) { _, id in
            if let id { model.acknowledge(id) }
        }
        .onDisappear { AppActivationPolicy.leave() }
    }

    private var groupsColumn: some View {
        ScrollView {
            VStack(spacing: 12) {
                if filtered.isEmpty {
                    ContentUnavailableView(
                        model.sessions.isEmpty ? "No sessions reporting" : "No matching sessions",
                        systemImage: "waveform.path.ecg",
                        description: Text(model.sessions.isEmpty
                            ? "Start a Claude Code or Codex turn. If nothing appears, repair hooks in Settings."
                            : "Clear a filter or try another search."))
                        .padding(.top, 60)
                } else {
                    ForEach(groups.buckets) { group in
                        StateGroupPanel(title: group.title, sessions: group.sessions, warm: group.warm,
                                        selection: $selection, model: model,
                                        showInclude: companionEnabled)
                    }
                }
            }
            .padding(.horizontal, 20).padding(.top, 4).padding(.bottom, 16)
        }
        .frame(maxWidth: .infinity)
    }

    private var detailColumn: some View {
        ScrollView {
            VStack(spacing: 12) {
                Group {
                    if let s = selectedSession {
                        DetailCard(session: s, model: model)
                    } else {
                        ContentUnavailableView("Select a session", systemImage: "sidebar.right")
                            .frame(maxWidth: .infinity, minHeight: 200)
                    }
                }
                .companionCard(radius: MacTheme.panelRadius)
                usageCard
            }
            .padding(.trailing, 20).padding(.top, 4).padding(.bottom, 16)
        }
        .frame(width: 380)
    }

    @ViewBuilder private var usageCard: some View {
        let providers = AccountUsageProvider.allCases.filter { model.isUsageCollectionEnabled($0) }
        if !providers.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(providers, id: \.self) { provider in
                    VStack(alignment: .leading, spacing: 6) {
                        Text("\(provider.displayName) usage").font(MacTheme.font(11, .heavy))
                            .foregroundStyle(MacTheme.ink3).textCase(.uppercase).kerning(0.6)
                        AccountUsageSummaryView(provider: provider, state: model.usageState(for: provider), compact: true)
                    }
                }
            }
            .font(MacTheme.font(12))
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .companionCard(radius: MacTheme.panelRadius)
        }
    }
}

/// One state bucket: a soft panel with a title row and summary-first rows.
private struct StateGroupPanel: View {
    let title: String
    let sessions: [AgentSession]
    let warm: Bool
    @Binding var selection: String?
    @ObservedObject var model: MenuBarModel
    let showInclude: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(title).font(MacTheme.font(14, .black)).foregroundStyle(MacTheme.ink)
                Text("\(sessions.count)").font(MacTheme.font(12, .heavy)).foregroundStyle(MacTheme.ink2)
                    .monospacedDigit()
                Spacer()
            }
            .padding(.horizontal, 6).padding(.top, 2)
            ForEach(sessions) { s in
                SummaryRow(session: s, isSelected: selection == s.id,
                           included: model.buddySessionIDs.contains(s.id), showInclude: showInclude,
                           onToggleInclude: { model.toggleBuddy(s.id) })
                    .onTapGesture { selection = s.id }
                    .contextMenu { AttentionPicker(session: s, model: model, style: .menu) }
            }
        }
        .padding(12)
        .background(ground, in: RoundedRectangle(cornerRadius: MacTheme.panelRadius, style: .continuous))
    }

    private var ground: some ShapeStyle {
        warm ? AnyShapeStyle(MacTheme.status(.requiresInput).opacity(0.10).blendMode(.normal))
             : AnyShapeStyle(MacTheme.bg2)
    }
}

/// The buddy header: cat + speech bubble on the left, search on the right.
private struct MacBuddyBar: View {
    @ObservedObject var model: MenuBarModel
    @ObservedObject var voice: VoiceChat
    @Binding var query: String
    var searchFocused: FocusState<Bool>.Binding
    @AppStorage(VoiceSettings.companionEnabledKey) private var companionEnabled = false
    @State private var greet = 0

    /// The buddy header reads "off" until the companion is opted in; otherwise the
    /// live Listening/Speaking/idle status.
    private var headline: LocalizedStringKey {
        if !companionEnabled { return "Voice companion off" }
        if voice.isListening { return "Listening…" }
        if voice.isSpeaking { return "Speaking…" }
        return "Tap the pet to talk"
    }

    /// "Buddy: all sessions" when nothing is scoped, else "Buddy: N selected".
    private var scopeLine: LocalizedStringKey {
        let n = model.buddySessionIDs.count
        return n == 0 ? "Buddy: all sessions" : "Buddy: \(n) selected"
    }

    var body: some View {
        HStack(spacing: 12) {
            PetFace(state: model.buddyState, voice: .init(voice.phase), greet: greet, bare: true, scale: 0.9)
                .onTapGesture { greet += 1; voice.toggle() }
            SpeechBubble {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        if !companionEnabled {
                            Image(systemName: "mic.slash").font(.caption).foregroundStyle(MacTheme.ink2)
                        }
                        Text(headline).font(MacTheme.font(13, .heavy)).foregroundStyle(MacTheme.ink)
                        if companionEnabled {
                            Text((voice.activeProvider ?? VoiceSettings.provider).display)
                                .font(MacTheme.font(10, .heavy))
                                .foregroundStyle(MacTheme.ink2)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(MacTheme.bg2, in: Capsule())
                        }
                    }
                    if let err = voice.errorText {
                        Text(err).font(MacTheme.font(11)).foregroundStyle(MacTheme.status(.error)).lineLimit(2)
                    } else if !voice.lastReply.isEmpty {
                        Text(voice.lastReply).font(MacTheme.font(11)).foregroundStyle(MacTheme.ink2).lineLimit(2)
                    } else if !voice.lastUserText.isEmpty {
                        Text(voice.lastUserText).font(MacTheme.font(11)).foregroundStyle(MacTheme.ink2).lineLimit(1)
                    } else {
                        Text(companionEnabled ? scopeLine : "Enable it in Settings › Voice, or tap the cat.")
                            .font(MacTheme.font(11, .semibold)).foregroundStyle(MacTheme.ink2)
                    }
                }
            }
            Spacer(minLength: 12)
            SearchPill(query: $query, focused: searchFocused)
        }
        .padding(.horizontal, 20).padding(.top, 6).padding(.bottom, 12)
        .sheet(isPresented: $voice.showConsent) { VoiceConsentSheet(voice: voice) }
    }
}

private struct SearchPill: View {
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
        .padding(.horizontal, 12).frame(width: 220, height: 30)
        .companionCard(radius: 15)
    }
}

/// Summary-first row (round 3): the agent's last summary is the main line,
/// the project is the eyebrow, the activity sits in small caps underneath.
private struct SummaryRow: View {
    let session: AgentSession
    var isSelected = false
    var included = false           // in the buddy's scoped context
    var showInclude = false        // only when the voice companion is on
    var onToggleInclude: () -> Void = {}

    private var state: TaskPresentationState { session.presentationState }
    private var mainLine: String {
        if let s = session.summary, !s.isEmpty { return s }
        return ToolActivity.label(for: session)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            StateGlyph(state: state)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(session.displayTitle).font(MacTheme.font(12, .bold)).foregroundStyle(MacTheme.ink2)
                    if session.name != nil {
                        Text(session.project).font(MacTheme.font(11)).foregroundStyle(MacTheme.ink3)
                    }
                    AgentBadge(agent: session.agent)
                    if let branch = session.branch {
                        Text(branch).font(MacTheme.mono(10)).foregroundStyle(MacTheme.ink3).lineLimit(1)
                    }
                    if session.isStuck {
                        Label("Stuck", systemImage: "exclamationmark.triangle.fill")
                            .font(MacTheme.font(10, .heavy)).foregroundStyle(MacTheme.status(.error))
                    }
                    if let glyph = session.effectiveAttention.rowGlyph {
                        Image(systemName: glyph).font(.caption2).foregroundStyle(MacTheme.ink3)
                            .help(session.effectiveAttention.title)
                    }
                    Spacer(minLength: 4)
                    Text(session.updatedAt, style: .relative)
                        .font(MacTheme.font(11, .semibold)).foregroundStyle(MacTheme.ink3).monospacedDigit()
                    if showInclude {
                        Button(action: onToggleInclude) {
                            Image(systemName: included ? "waveform.circle.fill" : "waveform.circle")
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(included ? MacTheme.accent : MacTheme.ink3)
                        .help(included ? "In the buddy's context" : "Add to the buddy's context")
                    }
                }
                Text(mainLine)
                    .font(MacTheme.font(14, .heavy)).foregroundStyle(MacTheme.ink)
                    .lineLimit(1).truncationMode(.tail)
                HStack(spacing: 6) {
                    Text(ToolActivity.label(for: session))
                        .font(MacTheme.font(10, .heavy)).textCase(.uppercase).kerning(0.6)
                        .foregroundStyle(MacTheme.status(state))
                    if let cost = session.estimatedCostUSD {
                        Text("\(session.costUSD == nil ? "≈ " : "")$\(cost, specifier: "%.2f")").font(MacTheme.font(10, .semibold))
                            .foregroundStyle(MacTheme.ink3).monospacedDigit()
                    }
                    if let effort = session.effort {
                        Text("effort \(effort)").font(MacTheme.font(10, .semibold)).foregroundStyle(MacTheme.ink3)
                    }
                    if let pr = session.prNumber {
                        Text("PR #\(pr)").font(MacTheme.font(10, .heavy)).foregroundStyle(MacTheme.ink2).monospacedDigit()
                    }
                    if let worktree = session.worktree {
                        Text(worktree).font(MacTheme.mono(10)).foregroundStyle(MacTheme.ink3).lineLimit(1)
                    }
                    if let observation = session.observationDescription {
                        Text(observation).font(MacTheme.font(10, .semibold)).foregroundStyle(MacTheme.ink3)
                    }
                }
                .lineLimit(1)
                if let child = ToolActivity.childSummary(for: session) {
                    Text(child).font(MacTheme.font(11, .semibold)).foregroundStyle(MacTheme.ink2)
                        .monospacedDigit().lineLimit(1)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .companionCard()
        .overlay {
            if isSelected {
                RoundedRectangle(cornerRadius: MacTheme.cardRadius, style: .continuous)
                    .strokeBorder(MacTheme.accent, lineWidth: 2)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
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
            Text(session.displayTitle).font(MacTheme.font(26, .black)).foregroundStyle(MacTheme.ink)
                .lineLimit(1).minimumScaleFactor(0.7)
            if session.name != nil {
                Text(session.project).font(MacTheme.font(12, .bold)).foregroundStyle(MacTheme.ink3)
            }
            HStack(spacing: 6) {
                Image(systemName: session.presentationState.symbolName).font(.system(size: 10, weight: .bold))
                Text(session.presentationState.label)
            }
            .font(MacTheme.font(12, .heavy))
            .foregroundStyle(MacTheme.status(session.presentationState))
            .padding(.horizontal, 12).padding(.vertical, 4)
            .background(MacTheme.status(session.presentationState).opacity(0.14), in: Capsule())

            if let approval = session.pendingApproval {
                RequestCard(session: session, approval: approval, model: model)
            } else {
                if let question = session.pendingQuestion {
                    if question.isAnswerable {
                        QuestionCardView(question: question) { answers in
                            model.answer(session.id, answers: answers)
                        }
                    } else {
                        Text(question.prompt).font(MacTheme.font(14, .heavy)).foregroundStyle(MacTheme.ink)
                            .fixedSize(horizontal: false, vertical: true)
                        Label("You're at the Mac — answer this in the agent's own prompt.", systemImage: "keyboard")
                            .font(MacTheme.font(11, .semibold)).foregroundStyle(MacTheme.ink2)
                    }
                } else if let s = session.summary, !s.isEmpty {
                    Text(s).font(MacTheme.font(14, .semibold)).foregroundStyle(MacTheme.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if session.agent == .codex {
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
                HStack(spacing: 8) {
                    Button(session.jumpsToDesktopThread ? "Open thread in ChatGPT" : "Jump to terminal") { model.jump(session) }
                        .buttonStyle(PillButtonStyle(kind: .filled(MacTheme.accent)))
                    Button { showTranscript = true } label: { Label("Recent output", systemImage: "text.alignleft") }
                        .buttonStyle(PillButtonStyle(kind: .soft))
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
                AttentionPicker(session: session, model: model, style: .segmented)
                Text(session.attentionOverride == nil
                     ? "Automatic: \(session.effectiveAttention.title.lowercased()) — followed while you're driving it, normal otherwise."
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
            if !approval.isAnswerable {
                // Presence: the agent's own prompt is taking this one.
                Label("You're at the Mac — answer this in the agent's own prompt.", systemImage: "keyboard")
                    .font(MacTheme.font(11, .semibold)).foregroundStyle(MacTheme.ink2)
                Button(session.jumpsToDesktopThread ? "Open thread" : "Jump ⏎") { model.jump(session) }
                    .buttonStyle(PillButtonStyle(kind: .filled(MacTheme.accent)))
            } else {
            HStack(spacing: 8) {
                SplitApproveButton(
                    approve: { model.decide(approval.id, .allow) },
                    always: { model.decide(approval.id, .alwaysAllow) },
                    session: { model.decide(approval.id, .allowSession) })
                    .background { Button("") { model.decide(approval.id, .allow) }.keyboardShortcut("a", modifiers: []).opacity(0) }
                Button("Deny") { model.decide(approval.id, .deny) }
                    .buttonStyle(PillButtonStyle(kind: .ghost))
                    .keyboardShortcut("d", modifiers: [])
                Button(session.jumpsToDesktopThread ? "Open thread" : "Jump ⏎") { model.jump(session) }
                    .buttonStyle(PillButtonStyle(kind: .ghost))
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
}

private struct VoiceConsentSheet: View {
    @ObservedObject var voice: VoiceChat
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Voice companion", systemImage: "waveform").font(.headline)
            Text("Tap the buddy to talk — it knows your sessions and can approve / answer for you. Pick the provider whose key you've filled in below. Switching applies instantly if the buddy is already listening.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Enabling opens the mic on the next tap and shares your live sessions with your selected provider, using your own key.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Enable") { voice.enableCompanion(); dismiss() }
                    .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
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
                    Text("Recent output").font(.headline)
                    Text(session.project).font(.caption).foregroundStyle(.secondary)
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
            ContentUnavailableView(
                "No recent output", systemImage: "text.alignleft",
                description: Text(output.statusLine.isEmpty
                                  ? "This session hasn't reported a transcript yet."
                                  : output.statusLine))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    if !output.statusLine.isEmpty {
                        Text(output.statusLine).font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(Array(output.entries.enumerated()), id: \.offset) { _, entry in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(entry.role == "assistant" ? "Assistant" : "You")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(entry.role == "assistant" ? Color.blue : Color.secondary)
                            Text(entry.text)
                                .font(.callout)
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
/// a segmented picker in the detail pane and radio items in a row's context
/// menu. `nil` is "automatic" — the daemon's own reading of recent interaction.
private struct AttentionPicker: View {
    enum Style { case segmented, menu }
    let session: AgentSession
    @ObservedObject var model: MenuBarModel
    let style: Style

    private var selection: Binding<SessionAttention?> {
        Binding(get: { session.attentionOverride },
                set: { model.setAttention(session.id, $0) })
    }

    var body: some View {
        switch style {
        case .segmented: picker.pickerStyle(.segmented)
        case .menu: picker.pickerStyle(.inline)
        }
    }

    private var picker: some View {
        Picker("Notifications", selection: selection) {
            Text(style == .menu
                 ? "Automatic (\(autoLevel.title.lowercased()))"
                 : "Auto").tag(SessionAttention?.none)
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
    var title: String {
        switch self {
        case .followed: "Followed"
        case .normal: "Normal"
        case .muted: "Muted"
        }
    }
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
        case .followed: "Everything about this session interrupts you."
        case .normal: "Only approvals and failures interrupt; the rest waits in Notification Center."
        case .muted: "Approvals show silently; nothing else interrupts."
        }
    }
}
