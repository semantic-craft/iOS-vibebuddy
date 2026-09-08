import Foundation
import Combine
import VibeBuddyKit

/// One in-memory edit state per existing Keychain account. Loads never write.
///
/// Presence and value are separate on purpose: the accounts table reports
/// "key saved" for every provider, and reading four secrets to do that would
/// raise a Keychain authorization prompt for each account this build was not
/// granted. `refresh()` asks only whether an item exists; `load()` decrypts,
/// and is called when the user opens the account or runs a test.
@MainActor
final class SettingsCredential: ObservableObject {
    let provider: VoiceProvider
    @Published private(set) var value = ""
    @Published private(set) var loaded = false
    @Published private(set) var present = false
    @Published private(set) var saveFailed = false
    @Published private(set) var revision = 0
    init(_ provider: VoiceProvider) { self.provider = provider }
    var configured: Bool {
        guard !saveFailed else { return false }
        return loaded ? !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty : present
    }
    /// Metadata only — never prompts.
    func refresh() { present = provider.hasAPIKey }
    func load() {
        refresh()
        guard !loaded else { return }
        value = provider.apiKey ?? ""
        loaded = true
    }
    func edit(_ value: String) {
        self.value = value
        loaded = true
        revision += 1
        saveFailed = KeychainStore.set(value, for: provider.keychainAccount) != 0
        present = !saveFailed && !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
@MainActor
final class SettingsCredentials: ObservableObject {
    private let entries = Dictionary(uniqueKeysWithValues: VoiceProvider.allCases.map { ($0, SettingsCredential($0)) })
    subscript(_ provider: VoiceProvider) -> SettingsCredential { entries[provider]! }
}
