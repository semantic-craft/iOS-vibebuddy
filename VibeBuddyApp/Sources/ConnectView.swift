import SwiftUI
import VibeBuddyKit

/// Connect screen: QR pairing is the primary path; manual entry is tucked away.
struct ConnectView: View {
    @EnvironmentObject private var connection: ConnectionStore

    @State private var host = ""
    @State private var port = "9876"
    @State private var token = ""
    @State private var showScanner = false
    @State private var showManual = false

    private var canConnect: Bool { !host.isEmpty && Int(port) != nil && !token.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text("vibebuddy").font(.largeTitle.bold())
                Text("在手机上盯着 Mac 上的 Claude Code 和 Codex 会话。")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 24)
            .padding(.top, 24)

            Spacer()

            VStack(spacing: 16) {
                Button {
                    showScanner = true
                } label: {
                    Label("扫码配对", systemImage: "qrcode.viewfinder")
                        .font(.headline).frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Text("打开 Mac 菜单栏 vibebuddy 的「Pair a phone」,扫那个二维码。")
                    .font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                Button(showManual ? "收起手动输入" : "手动输入地址") {
                    withAnimation(.smooth) { showManual.toggle() }
                }
                .font(.subheadline)

                if showManual { manualFields }

                Button("查看演示(无需 Mac)") { connection.enterDemo() }
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
            field("Token", placeholder: "菜单栏配对里的 token", text: $token)
            Button("连接") {
                if let portValue = Int(port) {
                    connection.save(PairingPayload(host: host, port: portValue, token: token))
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .frame(maxWidth: .infinity)
            .disabled(!canConnect)
        }
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    private func field(_ label: String, placeholder: String,
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
