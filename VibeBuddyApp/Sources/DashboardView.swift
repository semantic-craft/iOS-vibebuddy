import SwiftUI
import VibeBuddyKit

/// The iPhone dashboard, Companion style (docs/design/mac-companion-redesign.md):
/// the cat and its bubble on top, sessions in three state buckets, each row
/// summary-first; the row that needs you carries its request card inline.
struct DashboardView: View {
    @EnvironmentObject private var connection: ConnectionStore
    @EnvironmentObject private var dashboard: DashboardStore
    @EnvironmentObject private var voice: VoiceChat
    @AppStorage(VoiceSettings.companionEnabledKey) private var companionEnabled = false
    @State private var showSettings = false
    @State private var highlightId: String?

    private var groups: StateGroups { StateGroups(dashboard.allSessions) }

    var body: some View {
        ScrollViewReader { proxy in
        List {
            ForEach(groups.buckets) { bucket in
                section(bucket)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(CompanionPalette.bg)
        .onChange(of: dashboard.focusedSessionId) { _, _ in focus(proxy) }
        .onChange(of: dashboard.groups) { _, _ in
            if dashboard.focusedSessionId != nil { focus(proxy) }
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
                if let pairing = connection.pairing {
                    PairedMacStrip(pairing: pairing, state: dashboard.state)
                }
            }
            .background(CompanionPalette.bg)
        }
        .animation(.smooth, value: dashboard.groups)
        .overlay {
            if dashboard.groups.isEmpty { EmptyStateView(state: dashboard.state) }
        }
        .navigationTitle("vibebuddy")
        // The cat's bubble is the header now; a large title above it only
        // spends a screen's worth of blank space (and on iOS 26 hides behind
        // the inset).
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) { ConnectionDot(state: dashboard.state) }
            ToolbarItem(placement: .topBarTrailing) {
                Button { showSettings = true } label: { Image(systemName: "gearshape") }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button(connection.demo ? LocalizedStringKey("Exit demo") : LocalizedStringKey("Disconnect")) {
                    dashboard.stop(); connection.clear()
                }
                .font(.subheadline)
            }
        }
        .tint(CompanionPalette.accent)
        .sheet(isPresented: $showSettings) {
            // A sheet doesn't inherit the presenter's environment objects, so
            // re-inject `voice` — Settings restarts a live session on change.
            SettingsView()
                .environmentObject(voice)
                .environmentObject(dashboard)
        }
        .sheet(isPresented: $voice.showConsent) { VoiceConsentSheet(voice: voice) }
        .overlay(alignment: .bottom) {
            if let toast = dashboard.toast {
                Text(toast)
                    .font(CompanionType.font(13, .bold))
                    .foregroundStyle(CompanionPalette.ink)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(CompanionPalette.bg3, in: Capsule())
                    .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
                    .padding(.bottom, 28)
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

    /// Scroll to and briefly highlight the session a deep link asked to open.
    /// No-ops (leaving the request pending) until that session is in the list, so
    /// a cold-start link still lands once the first snapshot arrives.
    private func focus(_ proxy: ScrollViewProxy) {
        guard let id = dashboard.focusedSessionId,
              dashboard.allSessions.contains(where: { $0.id == id }) else { return }
        dashboard.clearFocus()
        withAnimation(.smooth) { proxy.scrollTo(id, anchor: .center) }
        highlightId = id
        Task {
            try? await Task.sleep(for: .seconds(2))
            withAnimation { if highlightId == id { highlightId = nil } }
        }
    }

    /// One state bucket: a title row, then a card per session.
    private func section(_ bucket: StateGroups.Bucket) -> some View {
        Section {
            ForEach(bucket.sessions) { session in
                SessionRow(session: session, isSelected: highlightId == session.id)
                    .id(session.id)
                    .swipeActions(edge: .leading, allowsFullSwipe: true) {
                        attentionSwipeButtons(session)
                    }
                    .contextMenu { attentionMenu(session) }
                    .listRowInsets(.init(top: 4, leading: 16, bottom: 4, trailing: 16))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }
        } header: {
            // Sticky while its bucket scrolls, so it needs its own solid ground.
            BucketTitle(title: bucket.title, count: bucket.sessions.count)
                .padding(.horizontal, 8).padding(.vertical, 6)
                .background(bucket.warm ? CompanionPalette.status(.requiresInput).opacity(0.12) : CompanionPalette.bg2,
                            in: Capsule())
                .textCase(nil)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(CompanionPalette.bg)
                .listRowInsets(.init(top: 0, leading: 16, bottom: 0, trailing: 16))
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


private struct PairedMacStrip: View {
    let pairing: PairingPayload
    let state: DashboardStore.ConnectionState

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "laptopcomputer.and.iphone")
                .foregroundStyle(color)
                .frame(width: 18)
            Text("Connected to \(macName)")
                .font(CompanionType.font(11, .bold))
                .foregroundStyle(CompanionPalette.ink2)
                .lineLimit(1)
            Text(verbatim: "\(pairing.host):\(String(pairing.port))")   // no "9,877" grouping
                .font(CompanionType.mono(10))
                .foregroundStyle(CompanionPalette.ink3)
            Spacer(minLength: 8)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 6)
    }

    private var macName: String {
        let trimmed = pairing.macName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "Mac" : trimmed
    }

    private var color: Color {
        switch state {
        case .connected: CompanionPalette.accent
        case .connecting: CompanionPalette.status(.requiresInput)
        case .failed: CompanionPalette.status(.error)
        }
    }
}

/// Summary-first row (round 3): the agent's last summary is the main line,
/// the project is the eyebrow, the activity sits in small caps underneath.
/// A pending approval or question is answered right here (round 4).
private struct SessionRow: View {
    let session: AgentSession
    let isSelected: Bool
    @EnvironmentObject private var dashboard: DashboardStore
    @AppStorage(VoiceSettings.companionEnabledKey) private var companionEnabled = false

    private var included: Bool { dashboard.buddySessionIDs.contains(session.id) }
    private var state: TaskPresentationState { session.presentationState }
    private var mainLine: String {
        if let s = session.summary, !s.isEmpty { return s }
        return ToolActivity.label(for: session)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            StateGlyph(state: state)
            VStack(alignment: .leading, spacing: 4) {
                eyebrow
                Text(mainLine)
                    .font(CompanionType.font(15, .heavy))
                    .foregroundStyle(CompanionPalette.ink)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                activityLine
                if let child = ToolActivity.childSummary(for: session) {
                    Text(child)
                        .font(CompanionType.font(11, .semibold))
                        .foregroundStyle(CompanionPalette.ink2)
                        .monospacedDigit()
                        .lineLimit(1)
                }
                if let observation = session.observationDescription {
                    HStack(spacing: 5) {
                        Label(observation, systemImage: "waveform.path.ecg")
                        if let last = session.lastObservedAt {
                            Text("· \(last, style: .relative)")
                        }
                    }
                    .font(CompanionType.font(10, .semibold))
                    .foregroundStyle(CompanionPalette.ink3)
                }
                if let used = session.contextTokens, let window = session.contextWindow, window > 0 {
                    ContextBar(used: used, window: window)
                }
                if let approval = session.pendingApproval {
                    RequestCard(session: session, approval: approval)
                        .padding(.top, 4)
                }
                if let question = session.pendingQuestion {
                    QuestionCardView(question: question) { answer in
                        dashboard.answer(session.id, answer: answer)
                    }
                    .padding(.top, 4)
                }
                if session.canJump, session.pendingApproval == nil {
                    Button(session.jumpsToDesktopThread ? "Open thread in ChatGPT" : "Jump to terminal") {
                        dashboard.jump(session.id)
                    }
                    .buttonStyle(PillButtonStyle(kind: .soft, size: .small))
                    .padding(.top, 2)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .companionCard()
        .overlay {
            if isSelected {
                RoundedRectangle(cornerRadius: CompanionType.cardRadius, style: .continuous)
                    .strokeBorder(CompanionPalette.accent, lineWidth: 2)
            }
        }
    }

    private var eyebrow: some View {
        HStack(spacing: 6) {
            Text(session.project)
                .font(CompanionType.font(12, .bold))
                .foregroundStyle(CompanionPalette.ink2)
                .lineLimit(1)
            AgentBadge(agent: session.agent)
            if let branch = session.branch {
                Text(branch)
                    .font(CompanionType.mono(10))
                    .foregroundStyle(CompanionPalette.ink3)
                    .lineLimit(1)
            }
            if session.effectiveAttention != .normal {
                Image(systemName: session.effectiveAttention == .followed ? "bell.badge.fill" : "bell.slash.fill")
                    .font(.caption2)
                    .foregroundStyle(session.effectiveAttention == .followed
                                     ? CompanionPalette.status(.requiresInput) : CompanionPalette.ink3)
                    .accessibilityLabel(session.effectiveAttention.stateTitle)
            }
            if session.isStuck {
                Label("Stuck", systemImage: "exclamationmark.triangle.fill")
                    .font(CompanionType.font(10, .heavy))
                    .foregroundStyle(CompanionPalette.status(.error))
                    .labelStyle(.titleAndIcon)
            }
            Spacer(minLength: 8)
            if companionEnabled {
                Button { dashboard.toggleBuddy(session.id) } label: {
                    Image(systemName: included ? "waveform.circle.fill" : "waveform.circle")
                        .foregroundStyle(included ? CompanionPalette.accent : CompanionPalette.ink3)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(included ? "In the buddy's context" : "Add to the buddy's context")
            }
        }
    }

    private var activityLine: some View {
        HStack(spacing: 6) {
            Text(ToolActivity.label(for: session))
                .font(CompanionType.font(10, .heavy)).textCase(.uppercase).kerning(0.6)
                .foregroundStyle(CompanionPalette.status(state))
                .layoutPriority(1)
            if let model = session.model { Text(model).lineLimit(1).truncationMode(.tail) }
            if let tokens = session.tokens {
                Text("\(tokens.formatted()) tok").monospacedDigit()
            }
            if let cost = session.estimatedCostUSD {
                Text("≈ $\(cost, specifier: "%.2f")").monospacedDigit()
            }
            Spacer(minLength: 8)
            Label {
                Text(session.statusSince, style: .timer).monospacedDigit()
            } icon: {
                Image(systemName: session.status == .needsResponse ? "hourglass" : "clock")
            }
            .foregroundStyle(session.status == .needsResponse
                             ? CompanionPalette.status(.requiresInput) : CompanionPalette.ink3)
        }
        .font(CompanionType.font(10, .semibold))
        .foregroundStyle(CompanionPalette.ink3)
        .lineLimit(1)
    }
}

/// Round 4 on the phone: the request as a card you can judge before answering —
/// who asks, what for, the diff or command, then Approve ▾ / Deny / Jump.
private struct RequestCard: View {
    let session: AgentSession
    let approval: PendingApproval
    @EnvironmentObject private var dashboard: DashboardStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                AgentAvatar(agent: session.agent)
                VStack(alignment: .leading, spacing: 1) {
                    (Text(session.project).fontWeight(.black)
                     + Text(" wants to \(CompanionCopy.requestVerb(approval))"))
                        .font(CompanionType.font(13, .semibold))
                        .foregroundStyle(CompanionPalette.ink)
                    Text(approval.tool)
                        .font(CompanionType.font(11, .semibold))
                        .foregroundStyle(CompanionPalette.ink3)
                        .lineLimit(1)
                }
            }
            ApprovalBody(approval: approval)
            HStack(spacing: 8) {
                SplitApproveButton(
                    approve: { dashboard.decide(approval.id, .allow) },
                    always: { dashboard.decide(approval.id, .alwaysAllow) },
                    session: { dashboard.decide(approval.id, .allowSession) })
                Button("Deny") { dashboard.decide(approval.id, .deny) }
                    .buttonStyle(PillButtonStyle(kind: .ghost))
                if session.canJump {
                    Button(session.jumpsToDesktopThread ? "Thread" : "Jump") { dashboard.jump(session.id) }
                        .buttonStyle(PillButtonStyle(kind: .ghost))
                }
            }
            if session.agent == .grok, let mode = approval.permissionMode, mode != "bypassPermissions" {
                Label {
                    Text("Grok will still ask in the terminal after Allow (permission mode: \(mode)). Set permission_mode = \"always-approve\" to approve from here.")
                } icon: {
                    Image(systemName: "terminal")
                }
                .font(CompanionType.font(10, .semibold))
                .foregroundStyle(CompanionPalette.ink3)
            }
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

private struct ConnectionDot: View {
    let state: DashboardStore.ConnectionState

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var color: Color {
        switch state {
        case .connecting: .yellow
        case .connected: .green
        case .failed: .red
        }
    }
    private var label: LocalizedStringKey {
        switch state {
        case .connecting: "Connecting"
        case .connected: "Connected"
        case .failed: "Reconnecting"
        }
    }
}

private struct EmptyStateView: View {
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
            ContentUnavailableView(
                "Disconnected", systemImage: "wifi.exclamationmark", description: Text(message))
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
