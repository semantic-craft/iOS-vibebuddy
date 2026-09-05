import SwiftUI
import VibeBuddyKit

struct DashboardView: View {
    private let presentationStates: [TaskPresentationState] = [
        .error, .requiresInput, .thinking, .completeUnread, .idle,
    ]
    @EnvironmentObject private var connection: ConnectionStore
    @EnvironmentObject private var dashboard: DashboardStore
    @EnvironmentObject private var voice: VoiceChat
    @AppStorage(VoiceSettings.companionEnabledKey) private var companionEnabled = false
    @State private var showSettings = false
    @State private var highlightId: String?

    var body: some View {
        ScrollViewReader { proxy in
        List {
            ForEach(presentationStates, id: \.self) { state in
                section(state, sessions: dashboard.allSessions.filter { $0.presentationState == state })
            }
        }
        .listStyle(.plain)
        .onChange(of: dashboard.focusedSessionId) { _, _ in focus(proxy) }
        .onChange(of: dashboard.groups) { _, _ in
            if dashboard.focusedSessionId != nil { focus(proxy) }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                BuddyView(groups: dashboard.groups, pulse: dashboard.cuePulse,
                          speaking: voice.isSpeaking, listening: voice.isListening,
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
            .background(.background)
        }
        .animation(.smooth, value: dashboard.groups)
        .overlay {
            if dashboard.groups.isEmpty { EmptyStateView(state: dashboard.state) }
        }
        .navigationTitle("vibebuddy")
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
                    .font(.subheadline)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(.quaternary))
                    .shadow(radius: 8, y: 2)
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

    @ViewBuilder
    private func section(_ state: TaskPresentationState, sessions: [AgentSession]) -> some View {
        let accent = Color(taskStatus: state.colorToken)
        if !sessions.isEmpty {
            Section {
                ForEach(sessions) { session in
                    SessionRow(session: session, isSelected: highlightId == session.id)
                        .id(session.id)
                        .listRowInsets(.init(top: 6, leading: 0, bottom: 6, trailing: 16))
                        .listRowBackground(highlightId == session.id
                                           ? accent.opacity(0.15) : Color.clear)
                }
            } header: {
                HStack(spacing: 6) {
                    Image(systemName: state.symbolName)
                    Text(state.label)
                    Text("\(sessions.count)").monospacedDigit().opacity(0.7)
                }
                .font(.footnote.weight(.semibold))
                .foregroundStyle(accent)
                .textCase(nil)
            }
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
            VStack(alignment: .leading, spacing: 1) {
                Text("Connected to \(macName)")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text("\(pairing.host):\(pairing.port)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color(.separator)).frame(height: 0.5)
        }
    }

    private var macName: String {
        let trimmed = pairing.macName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "Mac" : trimmed
    }

    private var color: Color {
        switch state {
        case .connected: .green
        case .connecting: .yellow
        case .failed: .red
        }
    }
}

private struct SessionRow: View {
    let session: AgentSession
    let isSelected: Bool
    @EnvironmentObject private var dashboard: DashboardStore
    @AppStorage(VoiceSettings.companionEnabledKey) private var companionEnabled = false

    private var included: Bool { dashboard.buddySessionIDs.contains(session.id) }
    private var accent: Color { Color(taskStatus: session.presentationState.colorToken) }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            TaskStatusIndicator(session.presentationState, isSelected: isSelected, size: 10)
                .padding(.top, 5)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(session.displayTitle).font(.headline)
                    if session.name != nil {
                        Text(session.project).font(.caption).foregroundStyle(.secondary)
                    }
                    if let branch = session.branch {
                        Text(branch)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    if session.isStuck {
                        Label("Stuck", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Color(taskStatus: TaskPresentationState.error.colorToken))
                            .labelStyle(.titleAndIcon)
                    }
                    if companionEnabled {
                        Spacer(minLength: 8)
                        Button { dashboard.toggleBuddy(session.id) } label: {
                            Image(systemName: included ? "waveform.circle.fill" : "waveform.circle")
                                .foregroundStyle(included ? AnyShapeStyle(accent) : AnyShapeStyle(.tertiary))
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(included ? "In the buddy's context" : "Add to the buddy's context")
                    }
                }

                if let summary = session.summary {
                    Text(summary)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                HStack(spacing: 6) {
                    Text(session.agent.shortName)
                    if let model = session.model { Text("· \(model)") }
                    if let tokens = session.tokens {
                        Text("· \(tokens.formatted()) tok").monospacedDigit()
                    }
                    if let cost = session.estimatedCostUSD {
                        Text("· \(session.costUSD == nil ? "≈ " : "")$\(cost, specifier: "%.2f")").monospacedDigit()
                    }
                    if let effort = session.effort { Text("· \(effort)") }
                    if let pr = session.prNumber { Text("· PR #\(pr)").monospacedDigit() }
                    Spacer(minLength: 8)
                    Label {
                        Text(session.statusSince, style: .timer).monospacedDigit()
                    } icon: {
                        Image(systemName: session.status == .needsResponse ? "hourglass" : "clock")
                    }
                    .foregroundStyle(session.status == .needsResponse
                                     ? AnyShapeStyle(accent) : AnyShapeStyle(.tertiary))
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)

                if let child = ToolActivity.childSummary(for: session) {
                    Text(child)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
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
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                }

                if let used = session.contextTokens, let window = session.contextWindow, window > 0 {
                    ContextBar(used: used, window: window)
                }

                if let approval = session.pendingApproval {
                    ApprovalCardView(approval: approval)
                        .padding(.top, 2)
                    if !approval.isAnswerable {
                        Label("You're at the Mac — answer this in the agent's own prompt.", systemImage: "keyboard")
                            .font(.caption).foregroundStyle(.secondary)
                            .padding(.top, 3)
                    }
                    if approval.isAnswerable {
                    HStack(spacing: 10) {
                        Button("Deny") { dashboard.decide(approval.id, .deny) }
                            .buttonStyle(.bordered).tint(.red)
                        Button("Approve") { dashboard.decide(approval.id, .allow) }
                            .buttonStyle(.borderedProminent).tint(.green)
                    }
                    .font(.subheadline)
                    .padding(.top, 4)
                    HStack(spacing: 10) {
                        Button("Always allow this") { dashboard.decide(approval.id, .alwaysAllow) }
                        Button("Allow all this session") { dashboard.decide(approval.id, .allowSession) }
                    }
                    .buttonStyle(.bordered).controlSize(.small).font(.caption)
                    .padding(.top, 1)
                    }
                    if let rule = approval.suggestedRule, approval.isAnswerable {
                        Text("Always allow adds \(rule) to Claude's own rules.")
                            .font(.caption2).foregroundStyle(.tertiary)
                            .padding(.top, 2)
                    }
                    if session.agent == .grok, let mode = approval.permissionMode, mode != "bypassPermissions" {
                        Label {
                            Text("Grok will still ask in the terminal after Allow (permission mode: \(mode)). Set permission_mode = \"always-approve\" to approve from here.")
                        } icon: {
                            Image(systemName: "terminal")
                        }
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .padding(.top, 3)
                    }
                }

                if let question = session.pendingQuestion {
                    QuestionCardView(question: question) { answers in
                        dashboard.answer(session.id, answers: answers)
                    }
                    .padding(.top, 2)
                }

                if session.canJump {
                    Button(session.jumpsToDesktopThread
                           ? "Open thread in ChatGPT" : "Jump to terminal") {
                        dashboard.jump(session.id)
                    }
                    .buttonStyle(.bordered).font(.subheadline)
                    .padding(.top, 4)
                }
            }
        }
        .padding(.leading, 4)
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
