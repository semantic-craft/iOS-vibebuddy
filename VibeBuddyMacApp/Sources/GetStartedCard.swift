import AppKit
import SwiftUI
import VibeBuddyKit
import VibeBuddyMacCore

/// The iPhone app's App Store entry, rendered on the Mac: a QR the iPhone
/// Camera opens straight in the App Store, plus the same link as text (for
/// VoiceOver and for a Mac without a camera-equipped phone nearby), a copy
/// button and the system share sheet (AirDrop to the phone).
struct IPhoneAppStoreCard: View {
    var compact = false
    @State private var copied = false

    /// Rendered once per view; the URL is a constant.
    private static let qr: NSImage? = Pairing.qrImage(from: CompanionLinks.iPhoneAppStore.absoluteString)
        .map { NSImage(cgImage: $0, size: NSSize(width: 200, height: 200)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 14) {
                if let qr = Self.qr {
                    Image(nsImage: qr).interpolation(.none).resizable()
                        .frame(width: compact ? 96 : 116, height: compact ? 96 : 116)
                        .padding(6).background(.white, in: RoundedRectangle(cornerRadius: 6))
                        .accessibilityLabel("App Store QR code for VibeBuddy on iPhone")
                        .accessibilityIdentifier("mac-app-store-qr")
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("Scan with the iPhone Camera to open the App Store.")
                        .font(MacTheme.font(12)).foregroundStyle(MacTheme.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(CompanionLinks.iPhoneAppStore.absoluteString)
                        .font(MacTheme.mono(10)).foregroundStyle(MacTheme.ink3)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            // Below the QR row, and stacked in a narrow column, so neither
            // label is truncated and the column never grows past the grid cell.
            let layout = compact ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6))
                                 : AnyLayout(HStackLayout(spacing: 8))
            layout {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(CompanionLinks.iPhoneAppStore.absoluteString, forType: .string)
                    copied = true
                } label: {
                    Label(copied ? LocalizedStringKey("Link copied") : LocalizedStringKey("Copy App Store link"),
                          systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .accessibilityIdentifier("mac-copy-app-store-link")
                ShareLink(item: CompanionLinks.iPhoneAppStore) {
                    Label("Send to iPhone…", systemImage: "square.and.arrow.up")
                }
                .help("AirDrop, Messages or Mail the App Store link to your iPhone")
                .accessibilityIdentifier("mac-share-app-store-link")
            }
            .font(MacTheme.font(11))
        }
        .accessibilityElement(children: .contain)
    }
}

/// The Inbox's first-run checklist: hook agents, install the iPhone app,
/// pair. It shows until a phone has confirmed pairing (the goal), or until
/// hidden; the App Store card also lives in Devices & connection, so hiding
/// loses nothing. Steps are order-agnostic — the first undone one carries the
/// accent edge.
struct GetStartedCard: View {
    @ObservedObject var model: MenuBarModel
    @StateObject private var hookSetup = HookSetup()
    @AppStorage("dashboard.getStartedHidden") private var hidden = false

    enum Step: CaseIterable { case hookAgents, installPhoneApp, pair }

    private var hooked: [CLIHookStatus] { hookSetup.statuses.filter(\.hookInjected) }

    private var checklist: SetupChecklist<Step> {
        SetupChecklist([
            .init(.hookAgents, done: !hooked.isEmpty),
            // The Mac cannot see the phone's home screen; a registered phone is
            // the first evidence the app is installed.
            .init(.installPhoneApp, done: model.pairedPhone != nil),
            .init(.pair, done: model.pairedPhone?.confirmed == true),
        ])
    }

    var body: some View {
        if !hidden && model.pairedPhone?.confirmed != true {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Get started").font(MacTheme.font(15, .semibold)).foregroundStyle(MacTheme.ink)
                    Text("\(checklist.doneCount) of \(checklist.total) done")
                        .font(MacTheme.font(11)).foregroundStyle(MacTheme.ink3)
                        .accessibilityIdentifier("mac-get-started-progress")
                    Spacer()
                    Button("Hide") { withAnimation(.snappy) { hidden = true } }
                        .buttonStyle(.borderless).font(MacTheme.font(11)).foregroundStyle(MacTheme.ink2)
                        .help("Pairing stays available in Settings › Devices & connection")
                        .accessibilityIdentifier("mac-get-started-hide")
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 236), spacing: 12)], alignment: .leading, spacing: 12) {
                    step(.hookAgents, title: "Hook your agents") { hookAgentsBody }
                    step(.installPhoneApp, title: "Get the iPhone app") { IPhoneAppStoreCard(compact: true) }
                    step(.pair, title: "Pair your iPhone") { pairBody }
                }
            }
            .padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .companionCard(MacTheme.bg2)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Get started")
            .accessibilityIdentifier("mac-get-started")
            .onAppear { hookSetup.refresh() }
            .task {
                while !Task.isCancelled {
                    await model.refreshConnectionCenter()
                    do { try await Task.sleep(for: .seconds(3)) } catch { return }
                }
            }
        }
    }

    private func step<Content: View>(_ step: Step, title: LocalizedStringKey,
                                     @ViewBuilder content: () -> Content) -> some View {
        let done = checklist.isDone(step)
        let current = checklist.current == step
        let number = checklist.position(of: step) ?? 0
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Group {
                    if done {
                        Image(systemName: "checkmark").font(.system(size: 10, weight: .bold))
                    } else {
                        Text(verbatim: "\(number)").font(MacTheme.font(11, .bold))
                    }
                }
                .foregroundStyle(done ? Color.onAccent : current ? MacTheme.accentText : MacTheme.ink3)
                .frame(width: 20, height: 20)
                .background(done ? MacTheme.accent : MacTheme.accent.opacity(current ? 0.14 : 0.06), in: Circle())
                .accessibilityHidden(true)
                Text(title).font(MacTheme.font(13, .semibold)).foregroundStyle(MacTheme.ink)
            }
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(MacTheme.bg3, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(current ? MacTheme.accent : MacTheme.line, lineWidth: current ? 2 : CompanionType.hairline)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Step \(number) of \(checklist.total): ") + Text(title))
        .accessibilityValue(done ? "Done" : current ? "Current step" : "Not started")
    }

    @ViewBuilder private var hookAgentsBody: some View {
        if hooked.isEmpty {
            Text(hookSetup.statuses.contains(where: \.configured)
                 ? "Install VibeBuddy's hooks so Claude Code and Codex report here."
                 : "No agent CLIs detected yet. Install Claude Code or Codex, then add the hooks.")
                .font(MacTheme.font(12)).foregroundStyle(MacTheme.ink2)
                .fixedSize(horizontal: false, vertical: true)
            Button("Set up hooks") { openSettings(.agentCLIs) }
                .buttonStyle(.borderedProminent).tint(MacTheme.accent)
                .accessibilityIdentifier("mac-get-started-hooks")
        } else {
            Text("Reporting: \(hooked.map(\.name).joined(separator: ", "))")
                .font(MacTheme.font(12)).foregroundStyle(MacTheme.ink2)
                .fixedSize(horizontal: false, vertical: true)
            Button("Agent CLIs") { openSettings(.agentCLIs) }
                .font(MacTheme.font(11))
        }
    }

    @ViewBuilder private var pairBody: some View {
        if model.pairingInProgress, let qr = model.qrImage {
            Image(nsImage: qr).interpolation(.none).resizable()
                .frame(width: 128, height: 128)
                .padding(8).background(.white, in: RoundedRectangle(cornerRadius: 6))
                .accessibilityLabel("Pairing QR code")
            Text("Scan in VibeBuddy on iPhone within 2 minutes.")
                .font(MacTheme.font(11)).foregroundStyle(MacTheme.ink2)
            Button("Close pairing code") { model.endPairing() }
                .disabled(model.changingPairing)
        } else {
            Text(model.pairedPhone == nil
                 ? "Same Wi-Fi as this Mac: open VibeBuddy on iPhone and choose Scan to pair."
                 : "\(model.pairedPhone?.name ?? "iPhone") is registered. Show the code once more to confirm.")
                .font(MacTheme.font(12)).foregroundStyle(MacTheme.ink2)
                .fixedSize(horizontal: false, vertical: true)
            Button("Show connection code") { model.beginPairing() }
                .buttonStyle(.borderedProminent).tint(MacTheme.accent)
                .disabled(model.pairing == nil || model.changingPairing
                          || (model.useTailscale && !model.remoteAddressIsValid))
                .accessibilityIdentifier("mac-get-started-show-code")
            Button("Away from home? Devices & connection") { model.openConnectionSettings() }
                .buttonStyle(.borderless).font(MacTheme.font(11)).foregroundStyle(MacTheme.accentText)
        }
    }

    private func openSettings(_ page: SettingsPageID) {
        NotificationCenter.default.post(name: .openAppSettings, object: page)
    }
}
