import Foundation
import Combine
import VibeBuddyKit

/// One in-memory edit state per existing Keychain account. Loads never write.
@MainActor
final class SettingsCredential: ObservableObject {
    let provider: VoiceProvider
    @Published private(set) var value = ""
    @Published private(set) var loaded = false
    @Published private(set) var saveFailed = false
    @Published private(set) var revision = 0
    init(_ provider: VoiceProvider) { self.provider = provider }
    var configured: Bool { loaded && !saveFailed && !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    func load() {
        guard !loaded else { return }
        value = provider.apiKey ?? ""
        loaded = true
    }
    func edit(_ value: String) {
        self.value = value
        revision += 1
        saveFailed = KeychainStore.set(value, for: provider.keychainAccount) != 0
    }
}
@MainActor
final class SettingsCredentials: ObservableObject {
    private let entries = Dictionary(uniqueKeysWithValues: VoiceProvider.allCases.map { ($0, SettingsCredential($0)) })
    subscript(_ provider: VoiceProvider) -> SettingsCredential { entries[provider]! }
}
