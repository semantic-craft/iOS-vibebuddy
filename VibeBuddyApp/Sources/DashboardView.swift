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
        .animation(.smooth, value: dashboard.groups)
        .overlay {
            if dashboard.groups.isEmpty { EmptyStateView(state: dashboard.state) }
        }
        .navigationTitle("vibebuddy")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) { ConnectionDot(state: dashboard.state) }
            ToolbarItem(placement: .topBarTrailing) {
                Button("断开") { dashboard.stop(); connection.clear() }
                    .font(.subheadline)
            }
        }
        .task(id: connection.pairing) {
            if let pairing = connection.pairing { dashboard.start(pairing) }
        }
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
            }
        }
        .padding(.leading, 4)
    }
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
