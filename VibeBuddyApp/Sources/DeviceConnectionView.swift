import SwiftUI
import VibeBuddyKit

struct DeviceConnectionView: View {
    @EnvironmentObject private var connection: ConnectionStore
    @EnvironmentObject private var dashboard: DashboardStore
    @EnvironmentObject private var connectionSync: RemoteConnectionSyncController
    @State private var showScanner = false
    @State private var copiedAddress = false

    private var macName: String {
        let name = connection.pairing?.macName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? String(localized: "Your Mac") : name
    }

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    Image(systemName: "desktopcomputer")
                        .font(.system(size: 28))
                        .foregroundStyle(CompanionPalette.accent)
                    Text(macName).font(CompanionType.font(26, .semibold))
                    Text(Self.status(pairing: connection.pairing, demo: connection.demo, state: dashboard.state))
                        .font(CompanionType.font(13))
                        .foregroundStyle(CompanionPalette.ink2)
                    if connection.pairing != nil, case .failed(let message) = dashboard.state {
                        Text(message).font(CompanionType.font(13)).foregroundStyle(CompanionPalette.ink2)
                    }
                }
                .padding(.vertical, 8)
            }
            if connectionSync.state != .idle {
                Section("Connection update from your Mac") {
                    syncStatus
                    if let address = connectionSync.address {
                        Text(address).font(CompanionType.mono(13)).foregroundStyle(CompanionPalette.ink2)
                    }
                    if connectionSync.canRetry {
                        Button("Retry connection check") { connectionSync.retry() }
                            .accessibilityIdentifier("remote-sync-retry")
                    }
                    NavigationLink("Remote network setup help") { RemoteConnectionView() }
                }
                .accessibilityIdentifier("remote-sync-status")
            }
            Section("Connection") {
                NavigationLink { RemoteConnectionView() } label: {
                    Label {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Connect away from home").font(CompanionType.font(16, .medium))
                            Text("Use your Mac on cellular with Headscale, Tailscale or Surge.")
                                .font(CompanionType.font(12)).foregroundStyle(CompanionPalette.ink2)
                        }
                        .padding(.vertical, 6)
                    } icon: {
                        Image(systemName: "network")
                    }
                }
                .accessibilityIdentifier("device-remote-connection")
            }
            Section("Manage") {
                Button { showScanner = true } label: {
                    Label("Scan to pair", systemImage: "qrcode.viewfinder")
                }
                .accessibilityIdentifier("settings-scan-to-pair")
                if let pairing = connection.pairing {
                    Button { dashboard.start(pairing) } label: {
                        Label("Reconnect", systemImage: "arrow.clockwise")
                    }
                }
                NavigationLink { MacCompanionSetupView() } label: {
                    Label("Pairing and Mac setup", systemImage: "desktopcomputer")
                }
            }
            if connection.pairing != nil || connection.demo {
                Section {
                    DisclosureGroup("Connection details & more") {
                        if let pairing = connection.pairing {
                            LabeledContent("Address") {
                                Text(verbatim: "\(pairing.host):\(pairing.port)")
                                    .font(CompanionType.mono(13)).textSelection(.enabled)
                            }
                            Button {
                                UIPasteboard.general.string = "\(pairing.host):\(pairing.port)"
                                copiedAddress = true
                            } label: {
                                Label(copiedAddress ? LocalizedStringKey("Address copied") : LocalizedStringKey("Copy address"), systemImage: "doc.on.doc")
                            }
                        }
                        Button(role: .destructive) {
                            connection.clear()
                            dashboard.forgetPairing()
                        } label: {
                            Label(connection.demo ? LocalizedStringKey("Exit demo") : LocalizedStringKey("Disconnect"), systemImage: "eject")
                        }
                    }
                }
            }
        }
        .font(CompanionType.font(15))
        .foregroundStyle(CompanionPalette.ink)
        .phoneList()
        .tint(CompanionPalette.accent)
        .navigationTitle("Device & connection")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showScanner) {
            PairingScannerSheet()
                .environmentObject(connection)
                .environmentObject(dashboard)
        }
    }

    @ViewBuilder
    private var syncStatus: some View {
        switch connectionSync.state {
        case .idle: EmptyView()
        case .received:
            Label("Remote address received. Waiting to check.", systemImage: "arrow.down.circle")
        case .checking:
            HStack {
                ProgressView()
                Text("Checking your Mac’s remote address…")
            }
        case .connected(let confirmation):
            Label("Remote connection verified", systemImage: "checkmark.circle.fill")
                .foregroundStyle(CompanionPalette.accent)
            if confirmation == .pending {
                Text("Connected. The confirmation has not reached your Mac yet.")
                    .font(CompanionType.font(12)).foregroundStyle(CompanionPalette.ink2)
            } else if confirmation == .unavailable {
                Text("The remote address is saved, but your Mac did not confirm the update. Send a new update from your Mac if needed.")
                    .font(CompanionType.font(12)).foregroundStyle(CompanionPalette.ink2)
            }
        case .failed(let failure):
            Text(failure.message).foregroundStyle(CompanionPalette.status(.error))
        }
    }

    static func status(pairing: PairingPayload?, demo: Bool, state: DashboardStore.ConnectionState) -> String {
        if demo { return String(localized: "Demo — no Mac connected") }
        guard let pairing else { return String(localized: "Not paired") }
        switch state {
        case .connecting: return String(localized: "Connecting")
        case .connected:
            return pairing.usingTailnetIPv4(pairing.host, port: pairing.port) != nil
                ? String(localized: "Remote connection active") : String(localized: "Connected")
        case .failed: return String(localized: "Offline")
        }
    }
}
