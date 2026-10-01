import SwiftUI
import VibeBuddyKit
import VibeBuddyMacCore

/// Shares the existing Cursor Cloud credential; this is independent of usage cookies.
struct CursorCloudSettingsSection: View {
    /// What the user is typing right now — never the stored key, which is
    /// written once and never read back.
    @State private var cloudAPIKeyDraft: String = ""
    @State private var cloudAPIKeySaved = false

    var body: some View {
        SettingsSection("Cursor cloud agents",
                        footnote: "A Cloud Agents API key from cursor.com/dashboard/api. Separate from the session Cookie and the cursor-agent CLI login. Used to read cloud agents, continue them and cancel runs.") {
            SettingsBlockRow {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Cursor API key").font(SettingsChrome.font(13, .semibold))
                    Text(verbatim: cloudKeyDetail).font(SettingsChrome.font(11.5)).foregroundStyle(MacTheme.ink2)
                    HStack(spacing: 8) {
                        SecureField("Cursor API key", text: $cloudAPIKeyDraft)
                            .textFieldStyle(.roundedBorder).labelsHidden().frame(width: 176)
                            .accessibilityLabel("Cursor API key")
                            .accessibilityIdentifier("cursor-cloud-api-key")
                            .onSubmit { saveCloudAPIKey() }
                        Button("Save") { saveCloudAPIKey() }
                            .disabled(cloudAPIKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || E2ERunConfiguration.current != nil)
                            .accessibilityIdentifier("save-cursorCloudAPIKey")
                            .accessibilityLabel("Save Cursor API key")
                        Button("Remove") {
                            CursorCloudAPIKeyStore.save(nil)
                            cloudAPIKeyDraft = ""
                            cloudAPIKeySaved = CursorCloudAPIKeyStore.isConfigured()
                        }
                        .disabled(!cloudAPIKeySaved || E2ERunConfiguration.current != nil)
                        .accessibilityIdentifier("remove-cursorCloudAPIKey")
                        .accessibilityLabel("Remove Cursor API key")
                    }
                }
            }
        }
        .onAppear { cloudAPIKeySaved = CursorCloudAPIKeyStore.isConfigured() }
    }
}

extension CursorCloudSettingsSection {
    /// Whether a key is stored — asked of the Keychain by **metadata only**, so
    /// reading this page never decrypts the key and never raises an
    /// authorization prompt. The key itself is never read back into the field:
    /// it is written once and thereafter only replaced or removed.
    var cloudKeyDetail: String {
        cloudAPIKeySaved
            ? String(localized: "A key is saved. Type a new one to replace it.")
            : String(localized: "No key saved. Cloud agents show as stored history only.")
    }

    func saveCloudAPIKey() {
        let trimmed = cloudAPIKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, E2ERunConfiguration.current == nil else { return }
        CursorCloudAPIKeyStore.save(trimmed)
        // Drop the draft the moment it is stored: nothing keeps the key in the
        // view hierarchy, and nothing prints it.
        cloudAPIKeyDraft = ""
        cloudAPIKeySaved = CursorCloudAPIKeyStore.isConfigured()
    }
}
