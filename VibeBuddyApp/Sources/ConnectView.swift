import SwiftUI
import VibeBuddyKit

/// v1 connect screen: manual host/port/token entry (works in the Simulator).
/// QR scanning (camera) is the next step and reuses `PairingPayload`.
struct ConnectView: View {
    @EnvironmentObject private var connection: ConnectionStore

    @State private var host = ""
    @State private var port = "9876"
    @State private var token = ""

    private var canConnect: Bool { !host.isEmpty && Int(port) != nil && !token.isEmpty }

    var body: some View {
        Form {
            Section {
                TextField("Host (e.g. 192.168.1.20)", text: $host)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("Port", text: $port)
                    .keyboardType(.numberPad)
                TextField("Token", text: $token)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } header: {
                Text("Connect to your Mac")
            } footer: {
                Text("From the vibebuddy menu-bar app: the host:port is shown there, and the token is in “Pair a phone”. QR scanning comes next.")
            }

            Button("Connect") {
                if let portValue = Int(port) {
                    connection.save(PairingPayload(host: host, port: portValue, token: token))
                }
            }
            .disabled(!canConnect)
        }
        .navigationTitle("vibebuddy")
    }
}
