import SwiftUI
import VibeBuddyKit
import VibeBuddyMacCore

/// Shares the existing Cursor Cloud credential; this is independent of usage cookies.
struct CursorCloudSettingsSection: View {
    /// What the user is typing right now — never the stored key, which is
    /// written once and never read back.
    @State private var cloudAPIKeyDraft: String = ""
    @State private var cloudAPIKeySaved = false
    @State private var cloudAPIKeyWriteFailed = false

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
                            guard CursorCloudAPIKeyStore.save(nil) == 0 else {
                                cloudAPIKeyWriteFailed = true
                                return
                            }
                            cloudAPIKeyWriteFailed = false
                            cloudAPIKeyDraft = ""
                            cloudAPIKeySaved = CursorCloudAPIKeyStore.isConfigured()
                        }
                        .disabled(!cloudAPIKeySaved || E2ERunConfiguration.current != nil)
                        .accessibilityIdentifier("remove-cursorCloudAPIKey")
                        .accessibilityLabel("Remove Cursor API key")
                    }
                    if cloudAPIKeyWriteFailed {
                        Text("Could not update the key in Keychain. Your draft is kept. Unlock Keychain and try again.")
                            .font(SettingsChrome.font(11.5))
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("cursor-cloud-key-write-error")
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
        guard CursorCloudAPIKeyStore.save(trimmed) == 0 else {
            cloudAPIKeyWriteFailed = true
            return
        }
        cloudAPIKeyWriteFailed = false
        // Drop the draft the moment it is stored: nothing keeps the key in the
        // view hierarchy, and nothing prints it.
        cloudAPIKeyDraft = ""
        cloudAPIKeySaved = CursorCloudAPIKeyStore.isConfigured()
    }
}
