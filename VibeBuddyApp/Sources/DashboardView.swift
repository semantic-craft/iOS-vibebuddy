import SwiftUI
import VibeBuddyKit

struct DashboardView: View {
    @EnvironmentObject private var connection: ConnectionStore
    @EnvironmentObject private var dashboard: DashboardStore

    var body: some View {
        List {
            section("需回应", systemImage: "exclamationmark.circle.fill",
                    sessions: dashboard.groups.needsResponse, accent: .orange)
            section("进行中", systemImage: "hourglass",
                    sessions: dashboard.groups.working, accent: .blue)
            section("已完成", systemImage: "checkmark.circle.fill",
                    sessions: dashboard.groups.done, accent: .green)
        }
        .overlay {
            if dashboard.groups.isEmpty {
                ContentUnavailableView(emptyTitle, systemImage: emptyIcon)
            }
        }
        .navigationTitle("vibebuddy")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Disconnect") {
                    dashboard.stop()
                    connection.clear()
                }
            }
        }
        .task(id: connection.pairing) {
            if let pairing = connection.pairing {
                dashboard.start(pairing)
            }
        }
        .onDisappear { dashboard.stop() }
    }

    private var emptyTitle: String {
        switch dashboard.state {
        case .connecting: "Connecting…"
        case .connected: "No active sessions"
        case .failed(let message): message
        }
    }

    private var emptyIcon: String {
        switch dashboard.state {
        case .connecting: "antenna.radiowaves.left.and.right"
        case .connected: "moon.zzz"
        case .failed: "wifi.exclamationmark"
        }
    }

    @ViewBuilder
    private func section(_ title: String, systemImage: String,
                         sessions: [AgentSession], accent: Color) -> some View {
        if !sessions.isEmpty {
            Section {
                ForEach(sessions) { SessionRow(session: $0, accent: accent) }
            } header: {
                Label("\(title) (\(sessions.count))", systemImage: systemImage)
                    .foregroundStyle(accent)
            }
        }
    }
}

struct SessionRow: View {
    let session: AgentSession
    let accent: Color

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle().fill(accent).frame(width: 10, height: 10).padding(.top, 5)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(session.project).font(.headline)
                    if let branch = session.branch {
                        Text(branch).font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let summary = session.summary {
                    Text(summary).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                }
                HStack(spacing: 8) {
                    Text(session.agent == .claudeCode ? "Claude" : "Codex")
                    if let model = session.model { Text(model) }
                    if let tokens = session.tokens { Text("\(tokens) tok") }
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
    }
}
