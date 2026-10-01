import SwiftUI
import VibeBuddyKit

struct CloudflareConnectionView: View {
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var connection: ConnectionStore
    @EnvironmentObject private var dashboard: DashboardStore
    @StateObject private var check = CloudflareConnectionAttempt()
    @State private var origin = ""
    @State private var clientID = ""
    @State private var secret = ""
    @State private var loaded = false
    @State private var unreadable = false
    @State private var removalFailed = false

    private var sourceID: String? {
        guard let pairing = connection.pairing, !connection.demo else { return nil }
        return dashboard.connectionSourceID(for: pairing) ?? connection.verifiedSourceID
    }

    var body: some View {
        Form {
            Section {
                Label("Cloudflare Access", systemImage: "cloud")
                    .font(CompanionType.font(24, .semibold))
                Text("Connect to your paired Mac without a phone VPN. First configure a Cloudflare Tunnel and a Service Auth policy on your Mac.")
                    .font(CompanionType.font(13)).foregroundStyle(CompanionPalette.ink2)
                Link("Cloudflare setup guide", destination: URL(string: "https://developers.cloudflare.com/cloudflare-one/access-controls/service-credentials/service-tokens/")!)
            }
            if sourceID == nil {
                Section {
                    Text("Connect to your Mac once using Wi-Fi or Tailscale before setting up Cloudflare. Live Mac status is needed to verify its identity.")
                }
            }
            Section {
                LabeledContent("Current connection") {
                    Text(connection.pairing?.isCloudflare == true ? LocalizedStringKey("Cloudflare") : LocalizedStringKey("Direct connection"))
                }
            }
            Section("Cloudflare connection") {
                TextField("HTTPS address", text: $origin)
                    .keyboardType(.URL).accessibilityIdentifier("cloudflare-origin")
                TextField("Client ID", text: $clientID)
                    .accessibilityIdentifier("cloudflare-client-id")
                SecureField("Client Secret", text: $secret)
                    .accessibilityIdentifier("cloudflare-client-secret")
                Text("Use a dedicated HTTPS domain without a path or custom port. Credentials stay in this iPhone’s Keychain.")
                    .font(CompanionType.font(12)).foregroundStyle(CompanionPalette.ink2)
            }.disabled(check.isChecking)
            Section {
                Button {
                    check.start(origin: origin, clientID: clientID, secret: secret,
                                sourceID: sourceID, connection: connection, onConnected: {
                        if let pairing = connection.pairing { dashboard.start(pairing) }
                        secret = ""
                    })
                } label: {
                    HStack {
                        Text(check.isChecking ? LocalizedStringKey("Checking connection…") : LocalizedStringKey("Check and save"))
                        Spacer()
                        if check.isChecking { ProgressView() }
                    }
                }
                .disabled(sourceID == nil || check.isChecking || origin.isEmpty || clientID.isEmpty || secret.isEmpty)
                .accessibilityIdentifier("cloudflare-check-save")
                if check.isChecking { Button("Cancel check") { check.cancel() } }
                if case .failure(let reason) = check.phase {
                    Text(reason.message).foregroundStyle(CompanionPalette.status(.error))
                        .accessibilityIdentifier("cloudflare-error")
                }
                if check.phase == .success {
                    Label("Live Mac status verified. Cloudflare connection saved.", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(CompanionPalette.accent)
                }
                if unreadable {
                    Text("Saved Cloudflare credentials could not be read. Unlock your iPhone or enter replacement credentials and check again.")
                }
                if removalFailed { Text("Could not remove saved credentials. Unlock your iPhone and try again. The connection is unchanged.") }
            } footer: {
                Text("Your saved connection stays unchanged until live status from the same Mac is verified.")
            }
            if connection.cloudflarePairing != nil {
                Section("Saved connections") {
                    if connection.pairing?.isCloudflare == true {
                        Button("Switch to saved direct connection") {
                            check.cancel(); connection.selectDirect()
                            if let pairing = connection.pairing { dashboard.start(pairing) }
                        }
                    } else {
                        Button("Use saved Cloudflare connection") {
                            check.cancel(); connection.selectCloudflare()
                            if let pairing = connection.pairing { dashboard.start(pairing) }
                        }
                    }
                    Button("Remove Cloudflare connection", role: .destructive) {
                        check.cancel()
                        guard connection.removeCloudflare() else { removalFailed = true; return }
                        removalFailed = false
                        origin = ""; clientID = ""; secret = ""
                        if let pairing = connection.pairing { dashboard.start(pairing) }
                    }
                }.disabled(check.isChecking)
            }
        }
        .font(CompanionType.font(15)).foregroundStyle(CompanionPalette.ink)
        .phoneList().tint(CompanionPalette.accent)
        .textInputAutocapitalization(.never).autocorrectionDisabled()
        .navigationTitle("Cloudflare Access").navigationBarTitleDisplayMode(.inline)
        .onAppear {
            guard !loaded else { return }; loaded = true
            guard let pairing = connection.cloudflarePairing,
                  let id = pairing.cloudflareCredentialID else { return }
            origin = "https://\(pairing.host)"
            do {
                let saved = try CloudflareCredentialStore.load(id: id)
                origin = saved.origin; clientID = saved.clientID; secret = saved.clientSecret
            } catch { unreadable = true }
        }
        .onDisappear { check.cancel(); secret = "" }
        .onChange(of: scenePhase) { _, phase in if phase != .active { check.cancel() } }
        .onChange(of: connection.pairing) { _, _ in if check.isChecking { check.cancel() } }
    }
}

@MainActor
final class CloudflareConnectionAttempt: ObservableObject {
    enum Failure: Equatable {
        case invalid, baseline, credentials, authentication, unavailable, wrongMac, changed
        var message: String {
            switch self {
            case .invalid: String(localized: "Enter a valid HTTPS domain, Client ID and Client Secret. Paths and custom ports are not supported.")
            case .baseline: String(localized: "Connect to your Mac once using Wi-Fi or Tailscale before setting up Cloudflare. Live Mac status is needed to verify its identity.")
            case .credentials: String(localized: "Cloudflare credentials could not be saved or read. Unlock your iPhone and try again. Your saved connection has not changed.")
            case .authentication: String(localized: "Connection authentication was refused. Check the Cloudflare Service Auth policy, device token and Mac pairing. Your saved connection has not changed.")
            case .unavailable: String(localized: "Could not receive live Mac status. Check the HTTPS address, Tunnel and Mac availability. Your saved connection has not changed.")
            case .wrongMac: String(localized: "This address returned a different Mac. Check the Tunnel destination. Your saved connection has not changed.")
            case .changed: String(localized: "The saved pairing changed during this check. Check again before saving this address.")
            }
        }
    }
    enum Phase: Equatable { case idle, checking, success, failure(Failure) }
    @Published private(set) var phase: Phase = .idle
    var isChecking: Bool { phase == .checking }
    private var task: Task<Void, Never>?
    private var attemptID: UUID?

    func start(origin: String, clientID: String, secret: String, sourceID: String?,
               connection: ConnectionStore,
               streamer: (any SnapshotStreaming)? = nil,
               saveCredential: @escaping (CloudflareCredentials, String) throws -> Void = { value, id in
                   _ = try CloudflareCredentialStore.save(value, id: id)
               },
               deleteCredential: @escaping (String) -> Void = { try? CloudflareCredentialStore.delete(id: $0) },
               onConnected: @escaping @MainActor () -> Void = {}) {
        cancel()
        guard let original = connection.pairing, !connection.demo,
              let sourceID, !sourceID.isEmpty else { phase = .failure(.baseline); return }
        guard let credentials = CloudflareCredentials(origin: origin, clientID: clientID, clientSecret: secret) else {
            phase = .failure(.invalid); return
        }
        let id = UUID()
        guard let candidate = original.usingCloudflare(origin: credentials.origin, credentialID: id.uuidString) else {
            phase = .failure(.invalid); return
        }
        let revision = connection.revision
        attemptID = id
        phase = .checking
        task = Task { @MainActor in
            defer {
                if attemptID == id { attemptID = nil; task = nil }
            }
            do {
                let snapshot = try await RemoteConnectionCheck.verify(candidate, streamer: streamer ?? WebSocketSnapshotClient(credentials: credentials))
                guard !Task.isCancelled, attemptID == id else { return }
                guard connection.revision == revision, connection.pairing == original, !connection.demo else {
                    phase = .failure(.changed); return
                }
                guard snapshot.sourceID == sourceID else { phase = .failure(.wrongMac); return }
                do { try saveCredential(credentials, id.uuidString) }
                catch { deleteCredential(id.uuidString); phase = .failure(.credentials); return }
                guard connection.commitCloudflare(candidate, sourceID: sourceID) else {
                    deleteCredential(id.uuidString)
                    phase = .failure(.credentials); return
                }
                phase = .success
                onConnected()
            } catch {
                guard !Task.isCancelled, attemptID == id else { return }
                if case CompanionConnectionFailure.authentication = error { phase = .failure(.authentication) }
                else if let error = error as? CompanionTransportError {
                    switch error {
                    case .authentication: phase = .failure(.authentication)
                    case .credentialsUnavailable, .keychainWriteFailed: phase = .failure(.credentials)
                    case .invalidAddress, .credentialOriginMismatch: phase = .failure(.invalid)
                    }
                } else { phase = .failure(.unavailable) }
            }
        }
    }
    func cancel() {
        task?.cancel(); task = nil; attemptID = nil
        if isChecking { phase = .idle }
    }
}
