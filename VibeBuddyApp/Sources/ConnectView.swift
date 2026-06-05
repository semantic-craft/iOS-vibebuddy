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

    private var canConnect: Bool { !host.isEmpty && Int(port) != nil && !token.isEmpty }

    /// Save a freshly entered pairing and play the pairing-success cue once.
    private func pair(_ payload: PairingPayload) {
        connection.save(payload)
        dashboard.confirmPairing()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text("vibebuddy").font(.largeTitle.bold())
                Text("Keep an eye on your Mac's Claude Code and Codex sessions from your phone.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 24)
            .padding(.top, 24)

            Spacer()

            VStack(spacing: 16) {
                Button {
                    showScanner = true
                } label: {
                    Label("Scan to pair", systemImage: "qrcode.viewfinder")
                        .font(.headline).frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Text("Open “Pair a phone” in the vibebuddy Mac menu bar and scan that QR code.")
                    .font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                Button(showManual ? LocalizedStringKey("Hide manual entry")
                                  : LocalizedStringKey("Enter address manually")) {
                    withAnimation(.smooth) { showManual.toggle() }
                }
                .font(.subheadline)

                if showManual { manualFields }

                Button("See the demo (no Mac needed)") { connection.enterDemo() }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
            }
            .padding(24)
        }
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
            .buttonStyle(.bordered)
            .controlSize(.large)
            .frame(maxWidth: .infinity)
            .disabled(!canConnect)
        }
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    private func field(_ label: LocalizedStringKey, placeholder: String,
                       text: Binding<String>, keyboard: UIKeyboardType = .default) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            TextField(placeholder, text: text)
                .font(.body.monospaced())
                .keyboardType(keyboard)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding(12)
                .background(.fill.quaternary, in: .rect(cornerRadius: 10))
        }
    }

    private var scannerSheet: some View {
        NavigationStack {
            QRScannerView { payload in
                pair(payload)
                showScanner = false
            }
            .ignoresSafeArea()
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
