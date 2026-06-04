import SwiftUI
import VibeBuddyKit
import VibeBuddyMacCore

struct DashboardView: View {
    @ObservedObject var model: MenuBarModel
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
            .searchable(text: $query, prompt: "搜索会话")
            .navigationTitle("vibebuddy")
        } detail: {
            if let s = selectedSession {
                DetailView(session: s, model: model)
            } else {
                ContentUnavailableView("选择一个会话", systemImage: "sidebar.right")
            }
        }
    }

    private var sidebar: some View {
        List(selection: $statusFilter) {
            Section("状态") {
                statusItem(.needsResponse, "需回应", .orange)
                statusItem(.working, "进行中", .blue)
                statusItem(.done, "已完成", .green)
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

private struct SessionRowView: View {
    let session: AgentSession
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 7) {
                Circle().fill(statusColor).frame(width: 8, height: 8)
                Text(session.project).fontWeight(.semibold)
            }
            if let s = session.summary {
                Text(s).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Text(session.agent == .claudeCode ? "Claude Code" : "Codex")
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
                    Text("Claude 想执行,需要你批准:").font(.headline)
                    Text(approval.commandPreview)
                        .font(.system(.body, design: .monospaced))
                        .padding(10)
                        .background(Color(nsColor: .textBackgroundColor))
                        .cornerRadius(8)
                    HStack(spacing: 10) {
                        Button("批准") { model.decide(approval.id, approve: true) }
                            .keyboardShortcut("a", modifiers: []).tint(.green)
                        Button("拒绝") { model.decide(approval.id, approve: false) }
                            .keyboardShortcut("d", modifiers: []).tint(.red)
                        Button("跳回终端") { }.disabled(true)   // STUB — sub-project 2
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    if let s = session.summary { Text(s).foregroundStyle(.secondary) }
                    Button("跳回终端") { }.disabled(true)   // STUB — sub-project 2
                }
                if let m = session.model {
                    Label(m, systemImage: "cpu").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
