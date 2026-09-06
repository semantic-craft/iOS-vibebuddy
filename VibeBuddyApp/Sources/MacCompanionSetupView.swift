import SwiftUI
import UIKit

/// One public destination shared by onboarding, settings, and connection help.
enum MacCompanionDownload {
    static let url = URL(string: "https://github.com/semantic-craft/iOS-vibebuddy/releases/latest")!
}

struct MacCompanionSteps: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            step("1", "Install on your Mac", "Open the download link on your Mac. Under Assets, download the DMG and drag the app to Applications.")
            step("2", "Show the pairing code", "Open “Pair a phone” in the Mac menu bar. Keep your Mac and iPhone on the same local network.")
            step("3", "Scan with your iPhone", "Scan the code to pair, then set up your agents in the Mac app. Keep the Mac app running and reachable for live updates.")
        }
    }

    private func step(_ number: String, _ title: LocalizedStringKey, _ detail: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(number).font(.subheadline.bold()).foregroundStyle(.tint)
                .frame(width: 28, height: 28)
                .background(Color.accentColor.opacity(0.12), in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
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
                Text("Link copied. Open it on your Mac.").font(.caption).foregroundStyle(.secondary)
            }
            if openFailed {
                Text("The link could not be opened. Copy it and open it on your Mac.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text(MacCompanionDownload.url.absoluteString)
                .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct MacCompanionSetupView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Your live tasks come from your own Mac. Install the free Mac companion and scan its code to unlock connected features.")
                    .foregroundStyle(.secondary)
                MacCompanionSteps()
                Text("For Apple Silicon Macs with macOS 14 or later. Install the companion on your Mac, not your iPhone.")
                    .font(.caption).foregroundStyle(.secondary)
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
