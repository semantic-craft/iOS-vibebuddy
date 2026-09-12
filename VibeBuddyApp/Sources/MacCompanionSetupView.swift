import SwiftUI
import VibeBuddyKit
import UIKit

/// One public destination shared by onboarding, settings, and connection help.
enum MacCompanionDownload {
    static let url = URL(string: "https://github.com/semantic-craft/iOS-vibebuddy/releases/latest")!
}

struct MacCompanionSteps: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            step("1", "Install on your Mac", "Open the download link on your Mac. Under Assets, download the DMG and drag the app to Applications.")
            step("2", "Show the pairing code", "Open “Pair a phone” in the Mac menu bar. Use the same LAN, or connect both devices to Tailscale for remote access.")
            step("3", "Scan with your iPhone", "Scan the code to pair, then set up your agents in the Mac app. Keep the Mac app running and reachable for live updates.")
        }
    }

    private func step(_ number: String, _ title: LocalizedStringKey, _ detail: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(number).font(CompanionType.font(15, .bold)).foregroundStyle(.tint)
                .frame(width: 28, height: 28)
                .background(Color.accentColor.opacity(0.12), in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(CompanionType.font(17, .semibold))
                Text(detail).font(CompanionType.font(15)).foregroundStyle(CompanionPalette.ink2)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct MacCompanionDownloadActions: View {
    @Environment(\.openURL) private var openURL
    @State private var copied = false
    @State private var openFailed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                openURL(MacCompanionDownload.url) { accepted in openFailed = !accepted }
            } label: {
                Label("Get the Mac companion", systemImage: "arrow.down.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered).controlSize(.large)

            Button {
                UIPasteboard.general.string = MacCompanionDownload.url.absoluteString
                copied = true
                UIAccessibility.post(notification: .announcement,
                                     argument: NSLocalizedString("Link copied. Open it on your Mac.", comment: ""))
            } label: {
                Label("Copy download link", systemImage: "doc.on.doc")
            }
            ShareLink(item: MacCompanionDownload.url) {
                Label("Share link to your Mac", systemImage: "square.and.arrow.up")
            }
            if copied {
                Text("Link copied. Open it on your Mac.").font(CompanionType.font(12)).foregroundStyle(CompanionPalette.ink2)
            }
            if openFailed {
                Text("The link could not be opened. Copy it and open it on your Mac.")
                    .font(CompanionType.font(12)).foregroundStyle(CompanionPalette.ink2)
            }
            Text(MacCompanionDownload.url.absoluteString)
                .font(CompanionType.font(12)).foregroundStyle(CompanionPalette.ink2).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct MacCompanionSetupView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Your live tasks come from your own Mac. Install the free Mac companion and scan its code to unlock connected features.")
                    .foregroundStyle(CompanionPalette.ink2)
                MacCompanionSteps()
                Text("For Apple Silicon Macs with macOS 14 or later. Install the companion on your Mac, not your iPhone.")
                    .font(CompanionType.font(12)).foregroundStyle(CompanionPalette.ink2)
                MacCompanionDownloadActions()
            }.padding(24)
        }
        .navigationTitle("Mac companion")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct MacCompanionSetupSheet: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            MacCompanionSetupView()
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
