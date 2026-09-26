import SwiftUI
import VibeBuddyKit

/// Connect screen: QR pairing is the primary path; manual entry is tucked away.
struct ConnectView: View {
    /// Reduce Motion: slides and scrolls become fades or cuts (HIG: Motion).
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @EnvironmentObject private var connection: ConnectionStore
    @EnvironmentObject private var dashboard: DashboardStore

    @State private var host = ""
    @State private var port = "9876"
    @State private var token = ""
    @State private var showScanner = false
    @State private var showManual = false
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

    private enum Step { case installMac, pair }

    /// Step 1 is "done" once the download link left this phone (shared, copied
    /// or skipped as already installed); step 2 is done when a pairing exists,
    /// which this screen never shows. Persisted so a second launch lands on
    /// "scan" as the primary action.
    @AppStorage("onboarding.macCompanionSent") private var macCompanionSent = false
    @State private var showShare = false
    @State private var linkCopied = false

    private var checklist: SetupChecklist<Step> {
        SetupChecklist([.init(.installMac, done: macCompanionSent), .init(.pair, done: false)])
    }

    /// Records that the Mac link is on its way and moves focus to step 2.
    private func markCompanionSent() {
        guard !macCompanionSent else { return }
        withAnimation(.smooth) { macCompanionSent = true }
        UIAccessibility.post(notification: .announcement,
                             argument: String(localized: "Step 1 done. Next, scan the connection code shown on your Mac."))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Connect your Mac")
                        .font(CompanionType.font(30, .semibold))
                        .tracking(CompanionType.tracking(30))
                        .foregroundStyle(CompanionPalette.ink)
                    Text("Two steps: install the free Mac companion on your Mac, then scan its code here. Your tasks stay on your own Mac.")
                        .font(CompanionType.font(14)).foregroundStyle(CompanionPalette.ink2)
                }
                VStack(spacing: 16) {
                    if let failure = connection.loadFailure { savedPairingNotice(failure) }
                    installStep
                    pairStep

                    NavigationLink { RemoteConnectionView() } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Label("Connect away from home", systemImage: "network")
                                .font(CompanionType.font(15, .medium))
                            Text("Scan your Mac’s remote code, then check your connection. Works with Tailscale, Headscale or Surge.")
                                .font(CompanionType.font(12)).foregroundStyle(CompanionPalette.ink2)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                        .companionCard()
                    }
                    .accessibilityIdentifier("initial-remote-connection")

                    Button(showManual ? LocalizedStringKey("Hide manual entry")
                                      : LocalizedStringKey("Enter address manually")) {
                        withAnimation(.smooth) { showManual.toggle() }
                    }
                    .font(CompanionType.font(13, .medium))

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
        .sheet(isPresented: $showScanner) {
            PairingScannerSheet(onManualEntry: { showManual = true })
        }
        .sheet(isPresented: $showShare) {
            ActivityShareSheet(items: [CompanionLinks.macDownload]) { completed in
                if completed { markCompanionSent() }
            }
            .presentationDetents([.medium, .large])
        }
    }

    /// A Mac is saved on this phone and this launch could not read it back.
    /// Saying so — with a retry — keeps the screen honest: scanning again is
    /// the way out, but the phone is not the new one this screen assumes.
    private func savedPairingNotice(_ failure: ConnectionStore.LoadFailure) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Your saved Mac could not be read", systemImage: "exclamationmark.triangle")
                .font(CompanionType.font(15, .medium))
            Text(failure == .protectedDataUnavailable
                 ? LocalizedStringKey("This phone was still locked when VibeBuddy started. Unlock it and try again — the saved Mac has not been removed.")
                 : LocalizedStringKey("The saved connection did not load. Try again, or scan your Mac's code below to replace it."))
                .font(CompanionType.font(12)).foregroundStyle(CompanionPalette.ink2)
                .fixedSize(horizontal: false, vertical: true)
            Button("Try again") { connection.reloadSavedPairing() }
                .buttonStyle(PhoneButtonStyle(kind: .soft, size: .small))
                .accessibilityIdentifier("connect-retry-saved-pairing")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .companionCard()
        .accessibilityIdentifier("connect-saved-pairing-notice")
    }

    /// Step 1: get the DMG onto the Mac. The phone cannot install it, so the
    /// primary verb moves the link (AirDrop, Notes, Mail); copying works with
    /// Universal Clipboard; "already installed" skips straight to scanning.
    private var installStep: some View {
        let done = checklist.isDone(.installMac)
        let current = checklist.current == .installMac
        return ConnectStepCard(number: 1, total: 2,
                               eyebrow: String(localized: "On your Mac"),
                               title: String(localized: "Install the free Mac companion"),
                               done: done, current: current) {
            if done {
                Text("Open the link on your Mac, drag VibeBuddy to Applications, then open it. Its menu-bar cat shows Devices & connection.")
                    .font(CompanionType.font(13)).foregroundStyle(CompanionPalette.ink2)
                Button("Send the link again") { showShare = true }
                    .buttonStyle(PhoneButtonStyle(kind: .quiet, size: .small))
                    .accessibilityIdentifier("initial-send-mac-link-again")
            } else {
                Button { showShare = true } label: {
                    Label("Send link to my Mac", systemImage: "paperplane")
                }
                .buttonStyle(PhoneButtonStyle(kind: .primary(CompanionPalette.accent), size: .wide))
                .accessibilityIdentifier("initial-send-mac-link")
                .accessibilityHint(Text("Opens the share sheet. AirDrop the download link to your Mac, or send it to Notes or Mail."))
                Text("AirDrop it to your Mac, or send it to Notes or Mail and open it there. For Apple Silicon Macs with macOS 14 or later.")
                    .font(CompanionType.font(12)).foregroundStyle(CompanionPalette.ink3)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 12) {
                    Button {
                        UIPasteboard.general.string = CompanionLinks.macDownload.absoluteString
                        linkCopied = true
                        markCompanionSent()
                    } label: {
                        Label(linkCopied ? LocalizedStringKey("Link copied") : LocalizedStringKey("Copy link"),
                              systemImage: linkCopied ? "checkmark" : "doc.on.doc")
                    }
                    .buttonStyle(PhoneButtonStyle(kind: .soft, size: .small))
                    .accessibilityIdentifier("initial-copy-mac-link")
                    Button("Already installed? Skip") { markCompanionSent() }
                        .buttonStyle(PhoneButtonStyle(kind: .soft, size: .small))
                        .accessibilityIdentifier("initial-skip-mac-install")
                }
            }
        }
        .accessibilityIdentifier("initial-mac-setup")
    }

    /// Step 2: the existing scan flow, promoted to the primary key once the
    /// link is on its way.
    private var pairStep: some View {
        let current = checklist.current == .pair
        return ConnectStepCard(number: 2, total: 2,
                               eyebrow: String(localized: "On your Mac, then here"),
                               title: String(localized: "Show the connection code, then scan it"),
                               done: false, current: current) {
            Button {
                showScanner = true
            } label: {
                Label("Scan to pair", systemImage: "qrcode.viewfinder")
            }
            .buttonStyle(PhoneButtonStyle(kind: current ? .primary(CompanionPalette.accent) : .quiet, size: .wide))
            .accessibilityIdentifier("initial-scan-to-pair")

            Text("On your Mac, open Devices & connection, choose Show connection code, then scan it.")
                .font(CompanionType.font(12)).foregroundStyle(CompanionPalette.ink2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityIdentifier("initial-pair-step")
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
        .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top)))
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

}

/// One numbered setup step. The current step carries the accent edge; a done
/// step swaps its number for a check. VoiceOver reads the whole card as
/// "Step 1 of 2: …, done / current step / not started" before its controls.
private struct ConnectStepCard<Content: View>: View {
    let number: Int
    let total: Int
    let eyebrow: String
    let title: String
    let done: Bool
    let current: Bool
    @ViewBuilder let content: Content

    private var stateValue: String {
        done ? String(localized: "Done") : current ? String(localized: "Current step") : String(localized: "Not started")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Group {
                    if done {
                        Image(systemName: "checkmark").font(.system(size: 13, weight: .bold))
                    } else {
                        Text(verbatim: "\(number)").font(CompanionType.font(15, .bold))
                    }
                }
                .foregroundStyle(done ? Color.onAccent : current ? CompanionPalette.accentText : CompanionPalette.ink3)
                .frame(width: 28, height: 28)
                .background(done ? CompanionPalette.accent : CompanionPalette.accent.opacity(current ? 0.14 : 0.06), in: Circle())
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(eyebrow)
                        .font(CompanionType.font(12, .medium))
                        .foregroundStyle(current ? CompanionPalette.accentText : CompanionPalette.ink3)
                    Text(title).font(CompanionType.font(17, .semibold)).foregroundStyle(CompanionPalette.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .companionCard()
        .overlay {
            RoundedRectangle(cornerRadius: CompanionType.cardRadius, style: .continuous)
                .strokeBorder(CompanionPalette.accent, lineWidth: current ? 2 : 0)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(String(localized: "Step \(number) of \(total): \(title)")))
        .accessibilityValue(Text(stateValue))
    }
}

/// The system share sheet with its completion reported back, so "sent" is
/// recorded only when the person actually handed the link off (AirDrop,
/// Notes, Mail…) and not when they dismissed the sheet.
private struct ActivityShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    let onFinish: (Bool) -> Void

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        controller.completionWithItemsHandler = { _, completed, _, _ in onFinish(completed) }
        return controller
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
