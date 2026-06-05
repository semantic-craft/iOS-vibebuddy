import SwiftUI
import VibeBuddyKit

struct DashboardView: View {
    @EnvironmentObject private var connection: ConnectionStore
    @EnvironmentObject private var dashboard: DashboardStore
    @EnvironmentObject private var voice: VoiceChat
    @AppStorage(VoiceSettings.companionEnabledKey) private var companionEnabled = false
    @State private var showSettings = false
    @State private var highlightId: String?

    var body: some View {
        ScrollViewReader { proxy in
        List {
            section("Needs response", sessions: dashboard.groups.needsResponse, accent: .orange)
            section("Working", sessions: dashboard.groups.working, accent: .blue)
            section("Done", sessions: dashboard.groups.done, accent: .green)
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
                          companionEnabled: companionEnabled) {
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
            SettingsView().environmentObject(voice)
        }
        .sheet(isPresented: $voice.showConsent) { VoiceConsentSheet(voice: voice) }
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
    private func section(_ title: LocalizedStringKey, sessions: [AgentSession], accent: Color) -> some View {
        if !sessions.isEmpty {
            Section {
                ForEach(sessions) { session in
                    SessionRow(session: session, accent: accent)
                        .id(session.id)
                        .listRowInsets(.init(top: 6, leading: 0, bottom: 6, trailing: 16))
                        .listRowBackground(highlightId == session.id
                                           ? accent.opacity(0.15) : Color.clear)
                }
            } header: {
                HStack(spacing: 6) {
                    Text(title)
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
    let accent: Color
    @EnvironmentObject private var dashboard: DashboardStore

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            RoundedRectangle(cornerRadius: 2)
                .fill(accent)
                .frame(width: 3)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(session.project).font(.headline)
                    if let branch = session.branch {
                        Text(branch)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    if session.isStuck {
                        Label("Stuck", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.red)
                            .labelStyle(.titleAndIcon)
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
                        Text("· ≈ $\(cost, specifier: "%.2f")").monospacedDigit()
                    }
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

                if let used = session.contextTokens, let window = session.contextWindow, window > 0 {
                    ContextBar(used: used, window: window)
                }

                if let approval = session.pendingApproval {
                    ApprovalCardView(approval: approval)
                        .padding(.top, 2)
                    HStack(spacing: 10) {
                        Button("Deny") { dashboard.decide(approval.id, approve: false) }
                            .buttonStyle(.bordered).tint(.red)
                        Button("Approve") { dashboard.decide(approval.id, approve: true) }
                            .buttonStyle(.borderedProminent).tint(.green)
                    }
                    .font(.subheadline)
                    .padding(.top, 4)
                }

                if let question = session.pendingQuestion {
                    QuestionCardView(question: question) { answer in
                        dashboard.answer(session.id, answer: answer)
                    }
                    .padding(.top, 2)
                }

                if session.terminalRef != nil {
                    Button("Jump to terminal") { dashboard.jump(session.id) }
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
/// the ask is here, not buried in Settings. Enabling persists; it does not open
/// the mic — the next tap starts the call.
private struct VoiceConsentSheet: View {
    @ObservedObject var voice: VoiceChat
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text("Tap the pet to talk — it holds a live voice conversation that knows your sessions and can approve / answer for you. Pick the provider whose key you've filled in below; switching applies instantly if it's already listening. The conversation uses your own key (kept in the Keychain, never uploaded or committed).")
                    .foregroundStyle(.secondary)
                Text("Enabling opens the mic on the next tap and shares your live sessions with your selected provider, using your own key.")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button { voice.enableCompanion(); dismiss() } label: {
                    Text("Enable").frame(maxWidth: .infinity)
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
