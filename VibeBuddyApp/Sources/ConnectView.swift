import SwiftUI
import VibeBuddyKit

/// v1 connect screen: manual host/port/token entry (works in the Simulator).
/// QR scanning (camera) is the next step and reuses `PairingPayload`.
struct ConnectView: View {
    @EnvironmentObject private var connection: ConnectionStore

    @State private var host = ""
    @State private var port = "9876"
    @State private var token = ""
    @State private var showScanner = false

    private var canConnect: Bool { !host.isEmpty && Int(port) != nil && !token.isEmpty }

    var body: some View {
        Form {
            Section {
                Button {
                    showScanner = true
                } label: {
                    Label("扫码配对", systemImage: "qrcode.viewfinder")
                }
            } footer: {
                Text("打开 Mac 上 vibebuddy 菜单栏的“Pair a phone”，扫描那个二维码即可。")
            }

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
        .sheet(isPresented: $showScanner) {
            NavigationStack {
                QRScannerView { payload in
                    connection.save(payload)
                    showScanner = false
                }
                .ignoresSafeArea()
                .navigationTitle("扫描配对二维码")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("取消") { showScanner = false }
                    }
                }
            }
        }
    }
}
