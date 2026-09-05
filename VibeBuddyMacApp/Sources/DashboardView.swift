import SwiftUI
import VibeBuddyKit
import VibeBuddyMacCore

struct DashboardView: View {
    @ObservedObject var model: MenuBarModel
    @Environment(\.openSettings) private var openSettings
    @State private var statusFilter: TaskPresentationState? = nil
    @State private var agentFilter: AgentKind? = nil
    @State private var query: String = ""
    // Demo instance pre-selects the approval session so the detail pane (diff +
    // Approve/Deny) is shown for screenshots; nil in normal use.
    @State private var selection: String? =
        ProcessInfo.processInfo.environment["VIBEBUDDY_DEMO"] == "1" ? "demo-edit" : nil
    @FocusState private var searchFocused: Bool
    @AppStorage(VoiceSettings.companionEnabledKey) private var companionEnabled = false

    private var filtered: [AgentSession] {
        SessionFilter.apply(model.sessions, status: nil, agent: agentFilter, query: query)
            .filter { statusFilter == nil || $0.presentationState == statusFilter }
            .sorted {
                $0.presentationState.attentionRank != $1.presentationState.attentionRank
                    ? $0.presentationState.attentionRank < $1.presentationState.attentionRank
                    : $0.updatedAt > $1.updatedAt
            }
    }
    private var selectedSession: AgentSession? { model.sessions.first { $0.id == selection } }

    var body: some View {
        NavigationSplitView {
            sidebar
        } content: {
            List(filtered, selection: $selection) { s in
                SessionRowView(session: s,
                               isSelected: selection == s.id,
                               included: model.buddySessionIDs.contains(s.id),
                               showInclude: companionEnabled,
                               onToggleInclude: { model.toggleBuddy(s.id) })
                    .tag(s.id)
                    .contextMenu {
                        AttentionPicker(session: s, model: model, style: .menu)
                    }
            }
            .searchable(text: $query, prompt: "Search sessions")
            .searchFocusedCompat($searchFocused)
            .navigationTitle("vibebuddy")
            .overlay {
                if filtered.isEmpty {
                    ContentUnavailableView(
                        model.sessions.isEmpty ? "No sessions reporting" : "No matching sessions",
                        systemImage: "waveform.path.ecg",
                        description: Text(model.sessions.isEmpty
                            ? "Start a Claude Code or Codex turn. If nothing appears, repair hooks in Settings."
                            : "Clear a filter or try another search.")
                    )
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                MacBuddyBar(model: model, voice: model.voiceChat)
            }
        } detail: {
            if let s = selectedSession {
                DetailView(session: s, model: model)
            } else {
                ContentUnavailableView("Select a session", systemImage: "sidebar.right")
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { openSettings() } label: { Image(systemName: "gearshape") }
                    .help("Settings")
            }
        }
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
                // ⏎ jumps to the selected session's terminal. Sessions without a
                // terminalRef are not excluded — they answer with "No terminal
                // recorded" in the detail pane. Ignored while typing in search so
                // it doesn't shadow the field's own Return.
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

    private var sidebar: some View {
        List {
            Section("Status") {
                allSessionsItem
                statusItem(.error)
                statusItem(.requiresInput)
                statusItem(.thinking)
                statusItem(.completeUnread)
                statusItem(.idle)
            }
            Section("Agent") {
                ForEach(SessionFilter.presentAgents(model.sessions), id: \.self) { a in
                    Button {
                        agentFilter = (agentFilter == a) ? nil : a
                    } label: {
                        HStack {
                            Text(a.displayName)
                            Spacer()
                            if agentFilter == a { Image(systemName: "checkmark") }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            ForEach(AccountUsageProvider.allCases, id: \.self) { provider in
                if model.isUsageCollectionEnabled(provider) {
                    Section("\(provider.displayName) Usage") {
                        AccountUsageSummaryView(
                            provider: provider,
                            state: model.usageState(for: provider),
                            compact: true
                        )
                    }
                }
            }
        }
    }

    private var allSessionsItem: some View {
        Button { statusFilter = nil } label: {
            HStack {
                Image(systemName: "rectangle.stack")
                    .frame(width: 9)
                    .foregroundStyle(.secondary)
                Text("All Sessions")
                Spacer()
                if statusFilter == nil { Image(systemName: "checkmark").font(.caption) }
                Text("\(model.sessions.count)").foregroundStyle(.secondary).monospacedDigit()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func statusItem(_ status: TaskPresentationState) -> some View {
        let count = model.sessions.filter { $0.presentationState == status }.count
        let selected = statusFilter == status
        return Button {
            statusFilter = selected ? nil : status   // click again to clear the filter
        } label: {
            HStack {
                TaskStatusIndicator(status, size: 9)
                Image(systemName: status.symbolName).font(.caption)
                Text(status.label)
                Spacer()
                if selected { Image(systemName: "checkmark").font(.caption) }
                Text("\(count)").foregroundStyle(.secondary).monospacedDigit()
            }
            .contentShape(Rectangle())   // whole row is clickable, not just the text
        }
        .buttonStyle(.plain)
    }
}

private extension View {
    /// `.searchFocused` is macOS 15+; on 14 we degrade gracefully (⌘F no-ops).
    @ViewBuilder
    func searchFocusedCompat(_ binding: FocusState<Bool>.Binding) -> some View {
        if #available(macOS 15.0, *) {
            searchFocused(binding)
        } else {
            self
        }
    }
}

/// The buddy header on the Mac dashboard: tap the face to talk to it.
private struct MacBuddyBar: View {
    @ObservedObject var model: MenuBarModel
    @ObservedObject var voice: VoiceChat
    @AppStorage(VoiceSettings.companionEnabledKey) private var companionEnabled = false

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
            PetFace(state: model.buddyState, speaking: voice.isSpeaking, listening: voice.isListening)
                .onTapGesture { voice.toggle() }
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    if !companionEnabled {
                        Image(systemName: "mic.slash").font(.caption).foregroundStyle(.secondary)
                    }
                    Text(headline).font(.headline)
                    if companionEnabled {
                        Text((voice.activeProvider ?? VoiceSettings.provider).display)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(.quaternary, in: Capsule())
                    }
                }
                if let err = voice.errorText {
                    Text(err).font(.caption).foregroundStyle(.red).lineLimit(2)
                } else if !voice.lastReply.isEmpty {
                    Text(voice.lastReply).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                } else if !voice.lastUserText.isEmpty {
                    Text(voice.lastUserText).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                if companionEnabled {
                    Text(scopeLine).font(.caption2).foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
        .sheet(isPresented: $voice.showConsent) { VoiceConsentSheet(voice: voice) }
    }
}

/// Inline consent before the voice companion's first use: you tapped to talk, so
/// the ask is here, not buried in Settings. Enabling persists; it does not open
/// the mic — the next tap starts the call.
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

private struct SessionRowView: View {
    let session: AgentSession
    var isSelected: Bool = false
    var included: Bool = false           // in the buddy's scoped context
    var showInclude: Bool = false        // only when the voice companion is on
    var onToggleInclude: () -> Void = {}
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                TaskStatusIndicator(session.presentationState, isSelected: isSelected, size: 9)
                Text(session.project).font(.headline)   // row subject = .headline (matches iOS)
                AgentSourceBadge(agent: session.agent)
                if session.isStuck {
                    Label("Stuck", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Color(taskStatus: TaskPresentationState.error.colorToken))
                }
                if let glyph = session.effectiveAttention.rowGlyph {
                    Image(systemName: glyph)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .help(session.effectiveAttention.title)
                }
                if showInclude {
                    Spacer(minLength: 8)
                    Button(action: onToggleInclude) {
                        Image(systemName: included ? "waveform.circle.fill" : "waveform.circle")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(included ? Color.accentColor : Color.secondary)
                    .help(included ? "In the buddy's context" : "Add to the buddy's context")
                }
            }
            HStack(spacing: 5) {
                Text(ToolActivity.label(for: session)).fontWeight(.medium)
                if let summary = session.summary, !summary.isEmpty {
                    Text("·").foregroundStyle(.tertiary)
                    Text(summary).lineLimit(1)
                }
            }
            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            if let child = ToolActivity.childSummary(for: session) {
                Text(child)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
            }
            HStack(spacing: 6) {
                Text(session.updatedAt, style: .relative).monospacedDigit()
                if let cost = session.estimatedCostUSD {
                    Text("≈ $\(cost, specifier: "%.2f")").monospacedDigit()
                }
            }
            .font(.caption2).foregroundStyle(.tertiary)
            if let observation = session.observationDescription {
                HStack(spacing: 5) {
                    Label(observation, systemImage: "waveform.path.ecg")
                    if let last = session.lastObservedAt {
                        Text("· \(last, style: .relative)")
                    }
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }
    private var statusColor: Color {
        switch session.status {
        case .needsResponse: return .orange
        case .working: return .blue
        case .done: return .green
        }
    }
}

struct AgentSourceBadge: View {
    let agent: AgentKind

    var body: some View {
        Text(agent.displayName)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(.quaternary, in: Capsule())
    }
}

private struct DetailView: View {
    let session: AgentSession
    @ObservedObject var model: MenuBarModel
    @State private var showTranscript = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(session.project).font(.title2.bold())
                Label(session.presentationState.label, systemImage: session.presentationState.symbolName)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(Color(taskStatus: session.presentationState.colorToken))
                if let approval = session.pendingApproval {
                    Text("Claude wants to run this — approve?").font(.headline)
                    Text(approval.commandPreview)
                        .font(.system(.body, design: .monospaced))
                        .padding(10)
                        .background(Color(nsColor: .textBackgroundColor))
                        .cornerRadius(8)
                    HStack(spacing: 10) {
                        Button("Approve") { model.decide(approval.id, .allow) }
                            .keyboardShortcut("a", modifiers: []).tint(.green)
                        Button("Deny") { model.decide(approval.id, .deny) }
                            .keyboardShortcut("d", modifiers: []).tint(.red)
                        Button(session.jumpsToDesktopThread ? "Open thread in ChatGPT" : "Jump to terminal") {
                            model.jump(session)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    HStack(spacing: 10) {
                        Button("Always allow this") { model.decide(approval.id, .alwaysAllow) }
                        Button("Allow all this session") { model.decide(approval.id, .allowSession) }
                    }
                    .buttonStyle(.bordered).controlSize(.small)
                    .help("Always allow: auto-approve this exact command in future. Allow all this session: stop asking for the rest of this run.")
                    if session.agent == .grok, let mode = approval.permissionMode, mode != "bypassPermissions" {
                        Label {
                            Text("Grok will still ask in the terminal after Allow (permission mode: \(mode)). Set permission_mode = \"always-approve\" to approve from here.")
                        } icon: {
                            Image(systemName: "terminal")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                } else {
                    if let s = session.summary { Text(s).foregroundStyle(.secondary) }
                    Button(session.jumpsToDesktopThread ? "Open thread in ChatGPT" : "Jump to terminal") {
                        model.jump(session)
                    }
                }
                // What the last jump actually achieved — focused the pane, only
                // raised the app, or found nothing to raise. Same wording as the
                // glance rows.
                if let outcome = model.jumpFeedback[session.id] {
                    Label(outcome.macMessage(for: session), systemImage: "arrow.uturn.forward")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .contentTransition(.opacity)
                }
                // Peek at what the agent has been doing without leaving the app.
                Button { showTranscript = true } label: {
                    Label("Recent output", systemImage: "text.alignleft")
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Notifications").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    AttentionPicker(session: session, model: model, style: .segmented)
                    Text(session.attentionOverride == nil
                         ? "Automatic: \(session.effectiveAttention.title.lowercased()) — followed while you're driving it, normal otherwise."
                         : session.effectiveAttention.explanation)
                        .font(.caption2).foregroundStyle(.tertiary)
                }
                if let m = session.model {
                    Label(m, systemImage: "cpu").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .animation(.smooth(duration: 0.18), value: model.jumpFeedback)
        }
        .sheet(isPresented: $showTranscript) {
            TranscriptSheet(session: session, model: model)
        }
    }
}

/// A read-only peek at a session's recent output (user prompts + assistant
/// prose / tool activity), loaded on demand off the store actor.
private struct TranscriptSheet: View {
    let session: AgentSession
    @ObservedObject var model: MenuBarModel
    @Environment(\.dismiss) private var dismiss
    @State private var entries: [TranscriptEntry] = []
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
            entries = await model.transcript(for: session.id)
            loaded = true
        }
    }

    @ViewBuilder
    private var content: some View {
        if !loaded {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if entries.isEmpty {
            ContentUnavailableView(
                "No recent output", systemImage: "text.alignleft",
                description: Text("This session hasn't reported a transcript yet."))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
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
