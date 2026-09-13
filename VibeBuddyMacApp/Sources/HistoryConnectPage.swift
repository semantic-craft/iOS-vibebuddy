import AppKit
import SwiftUI
import VibeBuddyKit
import VibeBuddyMacCore

struct HistoryConnectPage: View {
    @State private var copied: String?
    private var setup: HistoryConnectionSetup {
        HistoryConnectionSetup(executablePath: Bundle.main.bundleURL
            .appendingPathComponent("Contents/MacOS/vibebuddy-mcp").path)
    }

    var body: some View {
        SettingsPageScaffold("Connect", subtitle: "Read local session history from your agents") {
            SettingsSection("Bundled executable", boxed: false) {
                Text(verbatim: setup.executablePath)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Copy path") { copy(setup.executablePath, label: "Path") }
                    .buttonStyle(PillButtonStyle(kind: .ghost, size: .small))
            }
            SettingsSection("Client configuration", boxed: false) {
                ForEach(HistoryConnectionSetup.Client.allCases, id: \.self) { client in
                    HStack(alignment: .top, spacing: 16) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(client.title).font(SettingsChrome.font(13, .semibold))
                            Text(client.instruction).font(SettingsChrome.font(11.5)).foregroundStyle(MacTheme.ink2)
                        }
                        Spacer(minLength: 8)
                        Button("Copy \(client.title)") { copy(setup.configuration(for: client), label: client.title) }
                            .buttonStyle(PillButtonStyle(kind: .ghost, size: .small))
                    }
                    .padding(.vertical, 8)
                    ScrollView(.horizontal) {
                        Text(verbatim: setup.configuration(for: client))
                            .font(.system(size: 10.5, design: .monospaced))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: true, vertical: true)
                    }
                }
            }
            SettingsSection("What agents can read", boxed: false) {
                Text("Sessions, projects, search, transcripts, saved summaries and optional live status. Grok Build provides a list and titles only.")
                Text("Open History to build the index. The setup command prints these configurations and an optional AGENTS.md rule. Copying does not change client settings.")
                    .foregroundStyle(MacTheme.ink2)
            }
            .font(SettingsChrome.font(12))
            if let copied {
                Text("\(copied) copied").font(SettingsChrome.font(11.5)).foregroundStyle(MacTheme.accentText)
                    .accessibilityIdentifier("history-connect-copy-feedback")
            }
        }
    }

    private func copy(_ text: String, label: String) {
        NSPasteboard.general.clearContents()
        if NSPasteboard.general.setString(text, forType: .string) { copied = label }
    }
}
