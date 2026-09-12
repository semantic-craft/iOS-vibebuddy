import SwiftUI
import VibeBuddyKit

/// Connect screen: QR pairing is the primary path; manual entry is tucked away.
struct ConnectView: View {
    @EnvironmentObject private var connection: ConnectionStore
    @EnvironmentObject private var dashboard: DashboardStore

    @State private var host = ""
    @State private var port = "9876"
    @State private var token = ""
    @State private var showScanner = false
    @State private var showManual = false
    @State private var showScannerHelp = false
    @State private var connectionError: String?

    private var canConnect: Bool { PairingPayload(host: host, port: Int(port) ?? 0, token: token).isValidConnection }

    /// Save a freshly entered pairing and play the pairing-success cue once.
    private func pair(_ payload: PairingPayload) {
        guard payload.isValidConnection else {
            connectionError = String(localized: "Enter a valid Mac host, port and pairing token.")
            return
        }
        connectionError = nil
        connection.save(payload)
        dashboard.confirmPairing()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Connect your Mac")
                        .font(CompanionType.font(30, .semibold))
                        .tracking(CompanionType.tracking(30))
                        .foregroundStyle(CompanionPalette.ink)
                    Text("Your live tasks come from your own Mac. Install the free Mac companion and scan its code to unlock connected features.")
                        .font(CompanionType.font(14)).foregroundStyle(CompanionPalette.ink2)
                }
                MacCompanionSteps()
                Text("For Apple Silicon Macs with macOS 14 or later. Install the companion on your Mac, not your iPhone.")
                    .font(CompanionType.font(12)).foregroundStyle(CompanionPalette.ink3)
                MacCompanionDownloadActions()

                VStack(spacing: 16) {
                    Button {
                        showScanner = true
                    } label: {
                        Label("Scan to pair", systemImage: "qrcode.viewfinder")
                    }
                    .buttonStyle(PhoneButtonStyle(kind: .primary(CompanionPalette.accent), size: .wide))

                    Text("Open “Pair a phone” in the vibebuddy Mac menu bar and scan that QR code.")
                        .font(CompanionType.font(12)).foregroundStyle(CompanionPalette.ink2)
                        .multilineTextAlignment(.center)

                    Button(showManual ? LocalizedStringKey("Hide manual entry")
                                      : LocalizedStringKey("Enter address manually")) {
                        withAnimation(.smooth) { showManual.toggle() }
                    }
                    .font(CompanionType.font(13, .medium))

                    Text("Away from home? Join the same Tailscale network on your Mac and iPhone, then use your Mac’s Tailscale address.")
                        .font(CompanionType.font(12)).foregroundStyle(CompanionPalette.ink3)
                    if let connectionError {
                        Text(connectionError)
                            .font(CompanionType.font(13)).foregroundStyle(CompanionPalette.status(.error))
                    }
                    if showManual { manualFields }

                    Button("See the demo (no Mac needed)") { connection.enterDemo() }
                        .font(CompanionType.font(13))
                        .foregroundStyle(CompanionPalette.ink2)
                        .padding(.top, 4)
                }
            }
            .padding(24)
        }
        .background(CompanionPalette.bg)
        .tint(CompanionPalette.accent)
        .sheet(isPresented: $showScanner) { scannerSheet }
    }

    private var manualFields: some View {
        VStack(spacing: 12) {
            field("Host", placeholder: "192.168.1.20", text: $host)
            field("Port", placeholder: "9876", text: $port, keyboard: .numberPad)
            field("Token", placeholder: "token from the menu-bar pairing", text: $token)
            Button("Connect") {
                if let portValue = Int(port) {
                    pair(PairingPayload(host: host, port: portValue, token: token))
                }
            }
            .buttonStyle(PhoneButtonStyle(kind: .quiet, size: .wide))
            .disabled(!canConnect)
        }
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    private func field(_ label: LocalizedStringKey, placeholder: String,
                       text: Binding<String>, keyboard: UIKeyboardType = .default) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(CompanionType.font(12)).foregroundStyle(CompanionPalette.ink3)
            TextField(placeholder, text: text)
                .font(CompanionType.mono(14))
                .keyboardType(keyboard)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding(12)
                .companionCard()
        }
    }

    private var scannerSheet: some View {
        NavigationStack {
            QRScannerView { payload in
                pair(payload)
                showScanner = false
            }
            .ignoresSafeArea()
            .safeAreaInset(edge: .bottom) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        DisclosureGroup("Can't find the QR code?", isExpanded: $showScannerHelp) {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("Install the companion on your Mac, then open “Pair a phone” in its menu bar. Use the same local network or connect both devices to Tailscale.")
                                    .font(CompanionType.font(15))
                                MacCompanionDownloadActions()
                            }.padding(.top, 12)
                        }
                        Button("Enter address manually") {
                            showManual = true
                            showScanner = false
                        }
                    }.padding()
                }
                .frame(maxHeight: showScannerHelp ? 360 : 112)
                .background(.regularMaterial)
            }
            .navigationTitle("Scan pairing QR")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { showScanner = false }
                }
            }
        }
    }
}
