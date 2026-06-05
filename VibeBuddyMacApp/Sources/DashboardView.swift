import SwiftUI
import VibeBuddyKit
import VibeBuddyMacCore

struct DashboardView: View {
    @ObservedObject var model: MenuBarModel
    @Environment(\.openSettings) private var openSettings
    @State private var statusFilter: SessionStatus? = .needsResponse
    @State private var agentFilter: AgentKind? = nil
    @State private var query: String = ""
    @State private var selection: String? = nil

    private var filtered: [AgentSession] {
        SessionFilter.apply(model.sessions, status: statusFilter, agent: agentFilter, query: query)
            .sorted {
                $0.status.attentionRank != $1.status.attentionRank
                    ? $0.status.attentionRank < $1.status.attentionRank
                    : $0.updatedAt > $1.updatedAt
            }
    }
    private var selectedSession: AgentSession? { model.sessions.first { $0.id == selection } }

    var body: some View {
        NavigationSplitView {
            sidebar
        } content: {
            List(filtered, selection: $selection) { s in
                SessionRowView(session: s).tag(s.id)
            }
            .searchable(text: $query, prompt: "Search sessions")
            .navigationTitle("vibebuddy")
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
                Button("") { statusFilter = .needsResponse }.keyboardShortcut("1", modifiers: .command)
                Button("") { statusFilter = .working }.keyboardShortcut("2", modifiers: .command)
                Button("") { statusFilter = .done }.keyboardShortcut("3", modifiers: .command)
            }
            .opacity(0)
        }
        .onDisappear { AppActivationPolicy.leave() }
    }

    private var sidebar: some View {
        List(selection: $statusFilter) {
            Section("Status") {
                statusItem(.needsResponse, "Needs Response", .orange)
                statusItem(.working, "Working", .blue)
                statusItem(.done, "Done", .green)
            }
            Section("Agent") {
                ForEach(SessionFilter.presentAgents(model.sessions), id: \.self) { a in
                    Button {
                        agentFilter = (agentFilter == a) ? nil : a
                    } label: {
                        HStack {
                            Text(a == .claudeCode ? "Claude Code" : "Codex")
                            Spacer()
                            if agentFilter == a { Image(systemName: "checkmark") }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func statusItem(_ status: SessionStatus, _ label: String, _ color: Color) -> some View {
        let count = model.sessions.filter { $0.status == status }.count
        return HStack {
            Circle().fill(color).frame(width: 9, height: 9)
            Text(label)
            Spacer()
            Text("\(count)").foregroundStyle(.secondary).monospacedDigit()
        }
        .tag(Optional(status))
    }
}

/// The buddy header on the Mac dashboard: tap the face to talk to it.
private struct MacBuddyBar: View {
    @ObservedObject var model: MenuBarModel
    @ObservedObject var voice: VoiceChat

    var body: some View {
        HStack(spacing: 12) {
            PetFace(state: model.buddyState, speaking: voice.isSpeaking, listening: voice.isListening)
                .onTapGesture { voice.toggle() }
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(voice.isListening ? "Listening…" : (voice.isSpeaking ? "Speaking…" : "Tap the pet to talk"))
                        .font(.headline)
                    Text((voice.activeProvider ?? VoiceSettings.provider).display)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                }
                if let err = voice.errorText {
                    Text(err).font(.caption).foregroundStyle(.red).lineLimit(2)
                } else if !voice.lastReply.isEmpty {
                    Text(voice.lastReply).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                } else if !voice.lastUserText.isEmpty {
                    Text(voice.lastUserText).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
    }
}

private struct SessionRowView: View {
    let session: AgentSession
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Circle().fill(statusColor).frame(width: 8, height: 8)
                Text(session.project).font(.headline)   // row subject = .headline (matches iOS)
                if session.isStuck {
                    Label("Stuck", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.red)
                }
            }
            if let s = session.summary {
                Text(s).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            HStack(spacing: 6) {
                Text(session.agent.displayName)
                if let cost = session.estimatedCostUSD {
                    Text("≈ $\(cost, specifier: "%.2f")").monospacedDigit()
                }
            }
            .font(.caption2).foregroundStyle(.tertiary)
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

private struct DetailView: View {
    let session: AgentSession
    @ObservedObject var model: MenuBarModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(session.project).font(.title2.bold())
                if let approval = session.pendingApproval {
                    Text("Claude wants to run this — approve?").font(.headline)
                    Text(approval.commandPreview)
                        .font(.system(.body, design: .monospaced))
                        .padding(10)
                        .background(Color(nsColor: .textBackgroundColor))
                        .cornerRadius(8)
                    HStack(spacing: 10) {
                        Button("Approve") { model.decide(approval.id, approve: true) }
                            .keyboardShortcut("a", modifiers: []).tint(.green)
                        Button("Deny") { model.decide(approval.id, approve: false) }
                            .keyboardShortcut("d", modifiers: []).tint(.red)
                        Button("Jump to terminal") { model.jump(session) }
                            .disabled(session.terminalRef == nil)
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    if let s = session.summary { Text(s).foregroundStyle(.secondary) }
                    Button("Jump to terminal") { model.jump(session) }
                        .disabled(session.terminalRef == nil)
                }
                if let m = session.model {
                    Label(m, systemImage: "cpu").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
