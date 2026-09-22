import SwiftUI
import VibeBuddyKit

struct DeviceConnectionView: View {
    @EnvironmentObject private var connection: ConnectionStore
    @EnvironmentObject private var dashboard: DashboardStore
    @EnvironmentObject private var connectionSync: RemoteConnectionSyncController
    @State private var showScanner = false
    @State private var copiedAddress = false
    @State private var showRemoteSetup = false
    @State private var confirmDisconnect = false

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
                        if let reason = dashboard.failure {
                            // Which link is missing, and the tap that fixes
                            // it when one does (ADR-0032).
                            ConnectionFailureCard(reason: reason, macName: connection.pairing?.macName,
                                                  openSetup: { showRemoteSetup = true })
                        } else {
                            Text(message).font(CompanionType.font(13)).foregroundStyle(CompanionPalette.ink2)
                        }
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
                        // Forgetting a Mac cannot be undone without its
                        // pairing code, and this row sits one tap from Copy
                        // address — so the real disconnect asks first.
                        // Leaving the demo destroys nothing and does not.
                        Button(role: .destructive) {
                            if connection.demo {
                                dashboard.forgetPairing()
                                connection.exitDemo()
                            } else {
                                confirmDisconnect = true
                            }
                        } label: {
                            Label(connection.demo ? LocalizedStringKey("Exit demo") : LocalizedStringKey("Disconnect"), systemImage: "eject")
                        }
                        .accessibilityIdentifier("connection-disconnect")
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
        .navigationDestination(isPresented: $showRemoteSetup) { RemoteConnectionView() }
        .sheet(isPresented: $showScanner) {
            PairingScannerSheet()
                .environmentObject(connection)
                .environmentObject(dashboard)
        }
        .confirmationDialog("Forget this Mac?", isPresented: $confirmDisconnect, titleVisibility: .visible) {
            Button("Forget Mac", role: .destructive) {
                connection.clear()
                dashboard.forgetPairing()
            }
            .accessibilityIdentifier("connection-disconnect-confirm")
            Button("Keep this Mac", role: .cancel) {}
        } message: {
            Text("This phone stops showing \(macName)'s sessions and alerts. To connect again you need the pairing code from that Mac.")
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
