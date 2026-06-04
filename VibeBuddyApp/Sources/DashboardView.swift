import SwiftUI
import VibeBuddyKit

struct DashboardView: View {
    @EnvironmentObject private var connection: ConnectionStore
    @EnvironmentObject private var dashboard: DashboardStore

    var body: some View {
        List {
            section("需回应", sessions: dashboard.groups.needsResponse, accent: .orange)
            section("进行中", sessions: dashboard.groups.working, accent: .blue)
            section("已完成", sessions: dashboard.groups.done, accent: .green)
        }
        .listStyle(.plain)
        .safeAreaInset(edge: .top, spacing: 0) {
            BuddyView(groups: dashboard.groups)
        }
        .animation(.smooth, value: dashboard.groups)
        .overlay {
            if dashboard.groups.isEmpty { EmptyStateView(state: dashboard.state) }
        }
        .navigationTitle("vibebuddy")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) { ConnectionDot(state: dashboard.state) }
            ToolbarItem(placement: .topBarTrailing) {
                Button(connection.demo ? "退出演示" : "断开") { dashboard.stop(); connection.clear() }
                    .font(.subheadline)
            }
        }
        .task(id: connection.pairing) {
            if let pairing = connection.pairing { dashboard.start(pairing) }
        }
        .task { if connection.demo { dashboard.startDemo() } }
        .onDisappear { dashboard.stop() }
    }

    @ViewBuilder
    private func section(_ title: String, sessions: [AgentSession], accent: Color) -> some View {
        if !sessions.isEmpty {
            Section {
                ForEach(sessions) { session in
                    SessionRow(session: session, accent: accent)
                        .listRowInsets(.init(top: 6, leading: 0, bottom: 6, trailing: 16))
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
                }

                if let summary = session.summary {
                    Text(summary)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                HStack(spacing: 6) {
                    Text(session.agent == .claudeCode ? "Claude" : "Codex")
                    if let model = session.model { Text("· \(model)") }
                    if let tokens = session.tokens {
                        Text("· \(tokens.formatted()) tok").monospacedDigit()
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
                        Button("拒绝") { dashboard.decide(approval.id, approve: false) }
                            .buttonStyle(.bordered).tint(.red)
                        Button("批准") { dashboard.decide(approval.id, approve: true) }
                            .buttonStyle(.borderedProminent).tint(.green)
                    }
                    .font(.subheadline)
                    .padding(.top, 4)
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
    private var label: String {
        switch state {
        case .connecting: "连接中"
        case .connected: "已连接"
        case .failed: "重连中"
        }
    }
}

private struct EmptyStateView: View {
    let state: DashboardStore.ConnectionState

    var body: some View {
        switch state {
        case .connecting:
            ContentUnavailableView("正在连接 Mac", systemImage: "antenna.radiowaves.left.and.right")
        case .connected:
            ContentUnavailableView(
                "没有进行中的会话", systemImage: "moon.zzz",
                description: Text("启动一个 Claude Code 或 Codex 会话,它会出现在这里。"))
        case .failed(let message):
            ContentUnavailableView(
                "连接断开", systemImage: "wifi.exclamationmark", description: Text(message))
        }
    }
}
