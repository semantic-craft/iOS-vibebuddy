import SwiftUI
import VibeBuddyKit

/// Tests the real authenticated stream before replacing a saved LAN address.
struct RemoteConnectionView: View {
    @EnvironmentObject private var connection: ConnectionStore
    @EnvironmentObject private var dashboard: DashboardStore
    @State private var host = ""
    @State private var port = "9876"
    @State private var message: String?
    @State private var attempt: Task<Void, Never>?

    private var candidate: PairingPayload? {
        connection.pairing?.usingTailnetIPv4(host, port: Int(port) ?? 0)
    }

    var body: some View {
        Form {
            Section {
                if connection.pairing != nil {
                    LabeledContent("Address") {
                        TextField("100.x.x.x", text: $host)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .font(CompanionType.mono(14))
                            .accessibilityLabel("Mac private IP (100.x.x.x)")
                            .accessibilityIdentifier("remote-mac-ip")
                    }
                    LabeledContent("Port") {
                        TextField("9876", text: $port)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .font(CompanionType.mono(14))
                            .accessibilityLabel("Port")
                    }
                    Button { connect() } label: {
                        HStack(spacing: 10) {
                            Text(attempt == nil ? "Test and use this address" : "Checking connection…")
                            Spacer()
                            if attempt != nil { ProgressView() }
                            else { Image(systemName: "arrow.right").font(.system(size: 13)) }
                        }
                    }
                    .disabled(candidate == nil || attempt != nil)
                    .accessibilityIdentifier("remote-test-connect")
                } else {
                    Text("Pair with your Mac first by scanning its code. Return here to switch the saved connection to Headscale without entering the pairing token again.")
                }
                if let message { Text(message).font(.footnote).textSelection(.enabled) }
            } header: {
                Text("Headscale address")
            } footer: {
                Text("Use the Mac’s Tailscale IPv4 address, not the Headscale server URL or Surge node address. Your current pairing stays saved if the check fails.")
            }
            .disabled(attempt != nil)
            .listRowBackground(CompanionPalette.bg3)
            Section {
                NavigationLink { setupGuide } label: {
                    Label("Set up Surge and your Mac", systemImage: "network")
                }
                NavigationLink { watchGuide } label: {
                    Label("Check status away from home", systemImage: "applewatch")
                }
            } header: {
                Text("Help").textCase(nil)
            }
            .listRowBackground(CompanionPalette.bg3)
        }
        .font(CompanionType.font(15))
        .foregroundStyle(CompanionPalette.ink)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .phoneList()
        .navigationTitle("Headscale & Surge")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            host = connection.pairing?.host ?? ""
            port = String(connection.pairing?.port ?? 9876)
        }
        .onDisappear { attempt?.cancel(); attempt = nil }
        .onChange(of: host) { _, _ in message = nil }
        .onChange(of: port) { _, _ in message = nil }
    }

    private var setupGuide: some View {
        List {
            Section("iPhone with Surge") {
                Text("In Surge, add a Tailscale policy and set its control-url to your Headscale server. Sign in there and route the Mac’s private IP through that policy. Keep Surge running on cellular.")
                Link("Surge setup guide", destination: URL(string: "https://manual.nssurge.com/policies/tailscale.html")!)
            }
            Section("Mac at home") {
                Text("Keep VibeBuddy and the Tailscale app running on your Mac, joined to the same Headscale server with incoming connections allowed. Surge can stay on; its Tailscale policy alone cannot receive connections to your Mac.")
                Link("Headscale Mac setup", destination: URL(string: "https://headscale.net/stable/usage/connect/apple/#macos")!)
            }
        }
        .font(CompanionType.font(14))
        .phoneList()
        .navigationTitle("Set up Surge and your Mac")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var watchGuide: some View {
        List {
            Section("Apple Watch") {
                Text("Your Watch receives status through this iPhone. Turn off Wi-Fi, keep Surge connected and open VibeBuddy to check a live task on both devices. A suspended iPhone may leave the Watch showing its last update; background alerts depend on push delivery.")
            }
        }
        .font(CompanionType.font(14))
        .phoneList()
        .navigationTitle("Check status away from home")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func connect() {
        guard let candidate, let original = connection.pairing else { return }
        message = nil
        attempt = Task { @MainActor in
            defer { attempt = nil }
            do {
                _ = try await RemoteConnectionCheck.verify(candidate)
                guard !Task.isCancelled, connection.pairing == original else { return }
                connection.save(candidate)
                // A changed pairing restarts DashboardView's keyed task. An
                // unchanged one needs an explicit reconnect after a refusal.
                if candidate == original { dashboard.start(candidate) }
                message = String(localized: "Live Mac status received. This address is now saved. Check the Watch’s latest update next.")
            } catch {
                guard !Task.isCancelled else { return }
                message = RemoteConnectionCheck.message(for: error)
            }
        }
    }
}

enum RemoteConnectionCheck {
    static func verify(_ pairing: PairingPayload,
                       streamer: any SnapshotStreaming = WebSocketSnapshotClient()) async throws -> Snapshot {
        // The production stream bounds its first snapshot to 15 seconds and
        // closes its socket when this iterator leaves scope or is cancelled.
        for try await snapshot in streamer.stream(pairing) {
            try Task.checkCancellation()
            return snapshot
        }
        throw URLError(.networkConnectionLost)
    }

    static func message(for error: Error) -> String {
        if case CompanionConnectionFailure.authentication = error {
            return String(localized: "Mac refused the saved pairing. Scan its pairing code again.")
        }
        return String(localized: "Could not receive Mac status. Check Surge’s Headscale connection and route, the Mac’s Tailscale incoming connections, and permission to reach this port. The saved address has not changed.")
    }
}
