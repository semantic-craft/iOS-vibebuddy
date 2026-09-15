import SwiftUI
import VibeBuddyKit

struct RemoteConnectionView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var connection: ConnectionStore
    @EnvironmentObject private var dashboard: DashboardStore
    @StateObject private var check = RemoteConnectionAttempt()
    @State private var host = ""
    @State private var port = "9876"
    @State private var scannedPairing: PairingPayload?
    @State private var initializedDraft = false
    @State private var showScanner = false
    @State private var showManual = false
    @State private var showNetworkSteps = true
    @State private var provider = NetworkProvider.surge

    private enum NetworkProvider: String, CaseIterable, Identifiable {
        case surge = "Surge", tailscale = "Tailscale"
        var id: String { rawValue }
    }

    private var candidate: PairingPayload? {
        (scannedPairing ?? connection.pairing)?.usingTailnetIPv4(host, port: Int(port) ?? 0)
    }

    var body: some View {
        Form {
            if case .success = check.phase {
                successSection
                Section {
                    Button("Done") { dismiss() }
                    Button("Check again") { connect() }
                }
            } else {
                Section {
                    Text("Your Mac, wherever you are")
                        .font(CompanionType.font(24, .semibold))
                    Text("Scan your Mac’s remote code, prepare your phone’s network, then check and save. Your current pairing stays saved until live status arrives.")
                        .font(CompanionType.font(13)).foregroundStyle(CompanionPalette.ink2)
                }
                Section("1. Get your Mac’s connection info") {
                    Button { showScanner = true } label: {
                        Label(scannedPairing == nil ? LocalizedStringKey("Scan remote pairing code") : LocalizedStringKey("Scan again"), systemImage: "qrcode.viewfinder")
                            .font(CompanionType.font(16, .medium))
                            .padding(.vertical, 6)
                    }
                    .accessibilityIdentifier("remote-scan-pairing")
                    Text("On your Mac, open Devices & connection, choose Away from Mac, then Show connection code. VibeBuddy detects the remote address automatically; enter it manually if needed.")
                        .font(CompanionType.font(12)).foregroundStyle(CompanionPalette.ink2)
                    if scannedPairing != nil {
                        Label("Pairing info received. Check the connection to finish.", systemImage: "qrcode")
                            .font(CompanionType.font(13))
                    }
                    DisclosureGroup("Enter address manually", isExpanded: $showManual) {
                        LabeledContent("Mac private IP") {
                            TextField("100.x.x.x", text: $host)
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                                .font(CompanionType.mono(14))
                                .accessibilityLabel("Mac private IP (100.x.x.x)")
                                .accessibilityIdentifier("remote-mac-ip")
                        }
                        Text("Use the Mac’s Tailscale IPv4 address, not the Headscale server URL or Surge node address.")
                            .font(CompanionType.font(12)).foregroundStyle(CompanionPalette.ink2)
                        DisclosureGroup("Advanced settings") {
                            LabeledContent("Port") {
                                TextField("9876", text: $port)
                                    .keyboardType(.numberPad)
                                    .multilineTextAlignment(.trailing)
                                    .font(CompanionType.mono(14))
                                    .accessibilityLabel("Port")
                            }
                        }
                        if scannedPairing == nil && connection.pairing == nil {
                            Text("Scan the Mac’s code to get pairing authorization. You can continue here after scanning.")
                                .font(CompanionType.font(12))
                        } else {
                            Text("This Mac’s pairing authorization will be reused.")
                                .font(CompanionType.font(12)).foregroundStyle(CompanionPalette.ink2)
                        }
                    }
                    if (scannedPairing != nil || showManual), !host.isEmpty, candidate == nil {
                        Text("Enter the Mac’s address from 100.64.0.0 to 100.127.255.255 and a valid port. A local Wi-Fi address cannot be used here.")
                            .font(CompanionType.font(12)).foregroundStyle(CompanionPalette.status(.error))
                    }
                }
                .disabled(check.isChecking)
                Section("2. Prepare your phone’s network") {
                    Picker("Network app", selection: $provider) {
                        ForEach(NetworkProvider.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    DisclosureGroup("Network setup steps", isExpanded: $showNetworkSteps) {
                        if provider == .surge {
                            Text("In Surge, add a Tailscale policy with your Headscale control-url and sign in. Confirm the Mac’s private IP uses this policy. Current Surge versions add routes for discovered devices automatically.")
                            Link("Surge setup guide", destination: URL(string: "https://manual.nssurge.com/policies/tailscale.html")!)
                        } else {
                            Text("In the Tailscale app, sign in to the same network as your Mac. If you use Headscale, choose your Headscale server before signing in. Keep Tailscale connected.")
                            Link("Tailscale and Headscale setup", destination: URL(string: "https://headscale.net/stable/usage/connect/apple/#ios")!)
                        }
                        Text("Keep VibeBuddy and Tailscale running on the Mac, with incoming connections allowed. Sign-in happens in your network app; VibeBuddy checks the connection.")
                    }
                    .font(CompanionType.font(13))
                }
                .disabled(check.isChecking)
                Section {
                    if let candidate {
                        LabeledContent("Mac private IP") {
                            Text(verbatim: "\(candidate.host):\(candidate.port)")
                                .font(CompanionType.mono(13))
                        }
                    }
                    Button { connect() } label: {
                        HStack {
                            Text(check.isChecking ? LocalizedStringKey("Checking connection…") : LocalizedStringKey("Check and save"))
                            Spacer()
                            if check.isChecking { ProgressView() }
                            else { Image(systemName: "arrow.right") }
                        }
                        .padding(.vertical, 6)
                    }
                    .disabled(candidate == nil || check.isChecking)
                    .accessibilityIdentifier("remote-test-connect")
                    if check.isChecking {
                        Button("Cancel check") { check.cancel() }
                    }
                    if case .failure(let failure) = check.phase {
                        Text(failure.message)
                            .font(CompanionType.font(13)).foregroundStyle(CompanionPalette.status(.error))
                            .accessibilityIdentifier("remote-connection-error")
                        if failure == .authentication {
                            Button("Scan to pair") { showScanner = true }
                        }
                    }
                } header: {
                    Text("3. Check live Mac status")
                } footer: {
                    Text("The address is saved only after your Mac accepts the pairing and sends live status. A failed or cancelled check keeps your saved pairing.")
                }
                Section {
                    NavigationLink { watchGuide } label: {
                        Label("Check status away from home", systemImage: "applewatch")
                    }
                }
            }
        }
        .font(CompanionType.font(15))
        .foregroundStyle(CompanionPalette.ink)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .phoneList()
        .navigationTitle("Connect away from home")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            guard !initializedDraft else { return }
            initializedDraft = true
            if let pairing = connection.pairing,
               pairing.usingTailnetIPv4(pairing.host, port: pairing.port) != nil {
                host = pairing.host
            }
            port = String(connection.pairing?.port ?? 9876)
        }
        .onDisappear { check.cancel() }
        .onChange(of: host) { _, _ in check.reset() }
        .onChange(of: port) { _, _ in check.reset() }
        .sheet(isPresented: $showScanner) {
            PairingScannerSheet(onManualEntry: { showManual = true }, onScan: { payload in
                check.reset()
                scannedPairing = payload
                host = payload.host
                port = String(payload.port)
                if candidate == nil { showManual = true }
            })
            .environmentObject(connection)
            .environmentObject(dashboard)
        }
    }

    private var successSection: some View {
        Section {
            Label("Live Mac status received", systemImage: "checkmark.circle.fill")
                .font(CompanionType.font(20, .semibold))
                .foregroundStyle(CompanionPalette.accent)
            Text("The remote address is saved. Turn off Wi-Fi, keep your remote network connected, then check again to confirm cellular access.")
                .font(CompanionType.font(13))
                .accessibilityIdentifier("remote-connection-success")
        }
    }

    private var watchGuide: some View {
        List {
            Section("Apple Watch") {
                Text("Your Watch receives status through this iPhone. Turn off Wi-Fi, keep your remote network connected and open VibeBuddy to check a live task on both devices. A suspended iPhone may leave the Watch showing its last update; background alerts depend on push delivery.")
            }
        }
        .font(CompanionType.font(14))
        .phoneList()
        .navigationTitle("Check status away from home")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func connect() {
        guard let candidate else { return }
        let original = connection.pairing
        check.start(candidate, connection: connection) {
            if original == nil { dashboard.confirmPairing() }
            if candidate == original { dashboard.start(candidate) }
        }
    }
}

@MainActor
final class RemoteConnectionAttempt: ObservableObject {
    enum Failure: Equatable {
        case authentication, unavailable, pairingChanged

        var message: String {
            switch self {
            case .authentication:
                String(localized: "Mac refused this pairing. Scan its current code, then check again. Your saved pairing has not changed.")
            case .unavailable:
                String(localized: "Could not receive live Mac status. Check your phone’s remote network, wake the Mac, and confirm VibeBuddy and Tailscale allow incoming connections. Your saved pairing has not changed.")
            case .pairingChanged:
                String(localized: "The saved pairing changed during this check. Check again before saving this address.")
            }
        }
    }

    enum Phase: Equatable {
        case idle, checking, success, failure(Failure)
    }

    @Published private(set) var phase: Phase = .idle
    private var task: Task<Void, Never>?
    private var attemptID: UUID?
    var isChecking: Bool { phase == .checking }

    func start(_ candidate: PairingPayload, connection: ConnectionStore,
               streamer: any SnapshotStreaming = WebSocketSnapshotClient(),
               onConnected: @escaping @MainActor () -> Void = {}) {
        cancel()
        let id = UUID()
        attemptID = id
        let original = connection.pairing
        let originalDemo = connection.demo
        phase = .checking
        task = Task { @MainActor in
            defer { if attemptID == id { task = nil; attemptID = nil } }
            do {
                _ = try await RemoteConnectionCheck.verify(candidate, streamer: streamer)
                guard !Task.isCancelled, attemptID == id else { return }
                guard connection.pairing == original, connection.demo == originalDemo else {
                    phase = .failure(.pairingChanged)
                    return
                }
                connection.save(candidate)
                phase = .success
                onConnected()
            } catch {
                guard !Task.isCancelled, attemptID == id else { return }
                if case CompanionConnectionFailure.authentication = error {
                    phase = .failure(.authentication)
                } else {
                    phase = .failure(.unavailable)
                }
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        attemptID = nil
        if isChecking { phase = .idle }
    }

    func reset() {
        cancel()
        phase = .idle
    }
}

enum RemoteConnectionCheck {
    static func verify(_ pairing: PairingPayload,
                       streamer: any SnapshotStreaming = WebSocketSnapshotClient()) async throws -> Snapshot {
        for try await snapshot in streamer.stream(pairing) {
            try Task.checkCancellation()
            return snapshot
        }
        throw URLError(.networkConnectionLost)
    }
}
