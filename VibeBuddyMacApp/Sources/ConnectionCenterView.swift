import SwiftUI
import VibeBuddyKit
import VibeBuddyMacCore

struct ConnectionCenterView: View {
    @ObservedObject var model: MenuBarModel
    var compact = false
    @State private var advancedExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 16 : 20) {
            macRow
            connectionMode
            if model.useTailscale { remoteNetwork }
            pairingCard
            if let phone = model.pairedPhone { phoneCard(phone) }
            if let transfer = model.remoteTransfer { transferCard(transfer) }
            if !compact { advanced }
        }
        .padding(.top, compact ? 0 : 16)
        .task {
            model.discoverRemoteAddress()
            while !Task.isCancelled {
                await model.refreshConnectionCenter()
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
            }
        }
    }

    private var macRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "desktopcomputer")
                .font(.system(size: 25)).foregroundStyle(MacTheme.accent)
                .frame(width: 42, height: 42)
                .background(MacTheme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 4) {
                Text(model.macDisplayName).font(MacTheme.font(15, .semibold))
                Text(model.pairingAddress).font(MacTheme.mono(11)).foregroundStyle(MacTheme.ink2)
            }
            Spacer(minLength: 0)
        }
    }

    private var connectionMode: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Connection method", selection: $model.useTailscale) {
                Text("Same Wi-Fi").tag(false)
                Text("Away from Mac").tag(true)
            }
            .pickerStyle(.segmented)
            .disabled(model.pairingInProgress || model.changingPairing || model.synchronizingConnection)
            .accessibilityIdentifier("mac-connection-method")
            Text(model.useTailscale
                 ? "Headscale / Tailscale · Bring the remote address to your iPhone."
                 : "Connect both devices to the same network, then scan this Mac’s code.")
                .font(MacTheme.font(11)).foregroundStyle(MacTheme.ink2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var remoteNetwork: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(model.remoteAddressIsValid ? "Remote address ready" : "Prepare this Mac’s network",
                      systemImage: model.remoteAddressIsValid ? "checkmark.circle" : "network")
                    .font(MacTheme.font(12, .semibold))
                Spacer(minLength: 0)
                Button { model.discoverRemoteAddress() } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Detect remote address")
                .disabled(model.pairingInProgress || model.changingPairing)
                .accessibilityLabel("Detect remote address")
            }
            if model.remoteAddressIsValid {
                Text(model.tailscaleHost).font(MacTheme.mono(12))
                Text("The address is ready. Your iPhone still needs to check the connection.")
                    .font(MacTheme.font(11)).foregroundStyle(MacTheme.ink2)
            } else {
                Text("Connect the Tailscale app on this Mac to your Headscale network and allow incoming connections. Surge alone cannot receive connections to this Mac.")
                    .font(MacTheme.font(11)).foregroundStyle(MacTheme.ink2)
                    .fixedSize(horizontal: false, vertical: true)
                Link("Mac network setup", destination: URL(string: "https://headscale.net/stable/usage/connect/apple/#macos")!)
                    .font(MacTheme.font(11))
            }
            if model.detectedRemoteAddresses.count > 1 {
                Text("Choose this Mac’s remote address:").font(MacTheme.font(11))
                ForEach(model.detectedRemoteAddresses, id: \.self) { address in
                    Button(address) { model.tailscaleHost = address }
                        .disabled(model.pairingInProgress || model.changingPairing)
                }
            }
            if compact || (!model.remoteAddressIsValid && !advancedExpanded) { addressField }
        }
        .padding(14)
        .background(MacTheme.accent.opacity(0.055), in: RoundedRectangle(cornerRadius: 10))
    }

    private var pairingCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Connect iPhone").font(MacTheme.font(14, .semibold))
            Text("Scan once to bring in the Mac address and pairing permission. iPhone checks the connection before saving.")
                .font(MacTheme.font(12)).foregroundStyle(MacTheme.ink2)
                .fixedSize(horizontal: false, vertical: true)
            if model.pairingInProgress {
                if let qr = model.qrImage {
                    Image(nsImage: qr).interpolation(.none).resizable()
                        .frame(width: compact ? 164 : 176, height: compact ? 164 : 176)
                        .padding(12).background(.white, in: RoundedRectangle(cornerRadius: 8))
                        .accessibilityLabel("Pairing QR code")
                }
                Text("Scan in VibeBuddy on iPhone within 2 minutes.")
                    .font(MacTheme.font(11)).foregroundStyle(MacTheme.ink2)
                Button("Close pairing code") { model.endPairing() }
                    .disabled(model.changingPairing)
            } else {
                Button("Show connection code") { model.beginPairing() }
                    .buttonStyle(.borderedProminent).tint(MacTheme.accent)
                    .disabled(model.pairing == nil || model.changingPairing
                              || (model.useTailscale && !model.remoteAddressIsValid))
                    .accessibilityIdentifier("mac-show-connection-code")
            }
            if model.useTailscale {
                Text("If needed, finish Headscale sign-in in Surge or Tailscale on your iPhone, then check again.")
                    .font(MacTheme.font(11)).foregroundStyle(MacTheme.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(MacTheme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }

    private func phoneCard(_ phone: PairedPhone) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(phone.name, systemImage: "iphone.gen3").font(MacTheme.font(13, .semibold))
                Spacer(minLength: 0)
                Text(phone.confirmed ? "Paired" : "Registered")
                    .font(MacTheme.font(11)).foregroundStyle(MacTheme.ink2)
            }
            if model.useTailscale {
                Text("Already paired? Send the remote address over the existing connection. Open VibeBuddy on your iPhone to receive it.")
                    .font(MacTheme.font(11)).foregroundStyle(MacTheme.ink2)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Sync to iPhone") { model.syncConnectionToPhone() }
                    .disabled(!model.canSyncConnection)
                    .accessibilityIdentifier("mac-sync-to-iphone")
                if !phone.confirmed || phone.deviceID == nil {
                    Text("Scan the connection code again to enable syncing for this phone.")
                        .font(MacTheme.font(11)).foregroundStyle(MacTheme.ink2)
                }
            }
            if !compact {
                DisclosureGroup("Device details") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(phone.subtitle).font(MacTheme.font(11))
                        Text("Last registered \(phone.lastSeen.formatted(date: .abbreviated, time: .shortened))")
                        Text(phone.pushRegistered ? "Push registered" : "Push pending")
                        Text("Saved pairing does not confirm a live connection or notification delivery.")
                        Button("Forget all phones", role: .destructive) { model.forgetPairedPhone() }
                            .disabled(model.changingPairing || model.synchronizingConnection)
                    }
                    .font(MacTheme.font(11)).foregroundStyle(MacTheme.ink2).padding(.top, 8)
                }
                .font(MacTheme.font(11))
            }
        }
    }

    private func transferCard(_ transfer: RemoteConnectionSyncStore.Transfer) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(transferTitle(transfer)).font(MacTheme.font(13, .semibold))
            Text(transfer.proposal.host).font(MacTheme.mono(11))
            Text(transferDetail(transfer)).font(MacTheme.font(11)).foregroundStyle(MacTheme.ink2)
                .fixedSize(horizontal: false, vertical: true)
            if transfer.outcome != .confirmed {
                Button("Cancel sync") { model.cancelConnectionSync() }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(MacTheme.ink3.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityIdentifier("mac-connection-sync-status")
    }

    private func transferTitle(_ transfer: RemoteConnectionSyncStore.Transfer) -> LocalizedStringKey {
        if transfer.isExpired(at: Date()) { return "Sync request expired" }
        switch transfer.outcome {
        case nil: return "Waiting for iPhone to receive"
        case .received: return "iPhone received the address · checking"
        case .confirmed: return "iPhone checked and saved"
        case .unreachable: return "iPhone could not reach this Mac"
        case .unauthorized: return "Pairing permission needs attention"
        case .cancelled: return "iPhone paused the check"
        }
    }

    private func transferDetail(_ transfer: RemoteConnectionSyncStore.Transfer) -> LocalizedStringKey {
        if transfer.isExpired(at: Date()) { return "This request lasted 5 minutes. Sync again when your iPhone is ready." }
        switch transfer.outcome {
        case nil: return "Open VibeBuddy on the paired iPhone. Its current address remains saved until the new connection passes its check."
        case .received: return "Waiting for iPhone to receive this Mac’s authenticated task status through the remote address."
        case .confirmed: return "iPhone reported a successful check. Turn off Wi-Fi on the phone and check once more to verify cellular access."
        case .unreachable: return "The phone kept its previous address. Check the remote network and incoming connections, then retry on iPhone or sync again."
        case .unauthorized: return "Scan this Mac’s current connection code on iPhone, then check again."
        case .cancelled: return "Open VibeBuddy on iPhone and retry the check. Its previous address stays saved until the check succeeds."
        }
    }

    private var addressField: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Mac remote IPv4 address", text: $model.tailscaleHost)
                .textFieldStyle(.roundedBorder)
                .disabled(model.pairingInProgress || model.changingPairing || model.synchronizingConnection)
                .accessibilityIdentifier("mac-remote-address")
            Text("Use this Mac’s 100.x address, not the Headscale server URL.")
                .font(MacTheme.font(10)).foregroundStyle(MacTheme.ink2)
        }
    }

    private var advanced: some View {
        DisclosureGroup("Advanced connection settings", isExpanded: $advancedExpanded) {
            VStack(alignment: .leading, spacing: 12) {
                addressField
                LabeledContent("Port", value: String(model.port))
                    .font(MacTheme.font(11))
                if !model.detectedRemoteAddresses.isEmpty {
                    Text("Detected on this Mac: \(model.detectedRemoteAddresses.joined(separator: ", "))")
                        .font(MacTheme.font(11)).foregroundStyle(MacTheme.ink2)
                }
            }
            .padding(.top, 12)
        }
        .font(MacTheme.font(12))
    }
}
