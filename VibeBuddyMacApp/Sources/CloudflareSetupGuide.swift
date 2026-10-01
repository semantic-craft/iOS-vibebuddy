import SwiftUI

/// Instructions only. Cloudflare owns Tunnel processes, policies and tokens.
struct CloudflareSetupGuide: View {
    let port: Int
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Cloudflare connection").font(MacTheme.font(22, .semibold))
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    step("1. Allow your iPhone with Service Auth",
                         "Protect the entire hostname with an Access self-hosted application. Use a Service Auth policy that includes only this device’s service token. Do not use Bypass. Save the Client ID and Client Secret securely.")
                    Link("Access service token instructions", destination: URL(string: "https://developers.cloudflare.com/cloudflare-one/access-controls/service-credentials/service-tokens/")!)
                    step("2. Connect this Mac with cloudflared",
                         "Create a named Cloudflare Tunnel for this Mac using the official cloudflared connector. Publish the dedicated HTTPS hostname only after its Access policy is saved.")
                    LabeledContent("Local service") {
                        Text(verbatim: "http://127.0.0.1:\(port)")
                            .font(MacTheme.mono(12)).textSelection(.enabled)
                    }
                    Link("Cloudflare Tunnel instructions", destination: URL(string: "https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/get-started/create-remote-tunnel/")!)
                    step("3. Check and save on iPhone",
                         "After pairing normally, open Device & connection → Cloudflare connection on iPhone. Enter the HTTPS address, Client ID and Client Secret. Check and save only after receiving this Mac’s live status.")
                    Text("The Access service token is different from the Tunnel token and the existing Mac pairing token. Enter the device secret only on your iPhone; do not paste it into a command, QR code or support message.")
                    Text("Then turn off Wi-Fi and your phone VPN, check live updates and an action on cellular. Keep this Mac and cloudflared running. This guide does not check or manage the Tunnel.")
                }
                .font(MacTheme.font(12))
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(24)
        .frame(width: 540, height: 600)
    }

    private func step(_ title: LocalizedStringKey, _ detail: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(MacTheme.font(14, .semibold))
            Text(detail).foregroundStyle(MacTheme.ink2).fixedSize(horizontal: false, vertical: true)
        }
    }
}
