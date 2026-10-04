import Foundation
import Combine
import VibeBuddyKit

/// Saved values and drafts are separate: only explicit successful writes change
/// runtime configuration. Metadata refreshes never decrypt a secret.
@MainActor
final class SettingsCredential: ObservableObject {
    @MainActor
    struct Storage {
        var exists: (String) -> Bool
        var read: (String) -> String?
        /// Must preserve the old value on failure (KeychainStore updates in place).
        var write: (String?, String) -> Bool

        /// Explicit acceptance runs consume the inherited key, never personal
        /// Keychain state. Editing cannot replace a process environment value.
        static func injectedKey(_ key: String?) -> Storage {
            let present = !(key ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            return Storage(exists: { _ in present }, read: { _ in present ? key : nil }, write: { _, _ in false })
        }

        static let live = Storage(
            exists: { KeychainStore.exists($0) },
            read: { KeychainStore.get($0) },
            write: { KeychainStore.set($0, for: $1) == 0 })
    }

    let provider: VoiceProvider
    private let storage: Storage
    @Published private(set) var value = ""
    @Published private(set) var loaded = false
    @Published private(set) var present = false
    @Published private(set) var draft = ""
    @Published private(set) var editing = false
    @Published private(set) var saveFailed = false
    @Published private(set) var removalFailed = false
    @Published private(set) var revision = 0

    init(_ provider: VoiceProvider, storage: Storage? = nil) {
        self.provider = provider
        if let storage { self.storage = storage }
        else if provider == .gemini, E2ERunConfiguration.current != nil {
            self.storage = .injectedKey(ProcessInfo.processInfo.environment["GEMINI_API_KEY"])
        } else { self.storage = .live }
    }
    var configured: Bool {
        loaded ? !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty : present
    }
    var canSave: Bool { editing && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    func refresh() { present = storage.exists(provider.keychainAccount) }
    /// Explicit tests load only the saved key. A cancelled/failed read is retried.
    func load() {
        refresh()
        guard !loaded || value.isEmpty else { return }
        guard let savedValue = storage.read(provider.keychainAccount) else { return }
        value = savedValue
        loaded = true
    }
    /// A configured account is not proof that Keychain returned its value.
    /// Callers must use this gate before starting a provider request.
    func loadForUse() -> String? {
        load()
        guard loaded, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return value
    }
    /// Replacement starts blank; opening an editor need not decrypt the old key.
    func beginEditing() {
        refresh()
        draft = ""
        saveFailed = false
        removalFailed = false
        editing = true
    }
    func edit(_ value: String) { draft = value }
    func cancel() {
        draft = ""
        editing = false
        saveFailed = false
        removalFailed = false
    }
    @discardableResult
    func save() -> Bool {
        guard canSave else { return false }
        let candidate = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard storage.write(candidate, provider.keychainAccount) else {
            saveFailed = true
            removalFailed = false
            return false
        }
        value = candidate
        loaded = true
        present = true
        revision += 1
        cancel()
        return true
    }
    @discardableResult
    func remove() -> Bool {
        guard storage.write(nil, provider.keychainAccount) else {
            removalFailed = true
            saveFailed = false
            return false
        }
        value = ""
        loaded = true
        present = false
        revision += 1
        cancel()
        return true
    }
}
@MainActor
final class SettingsCredentials: ObservableObject {
    private let entries = Dictionary(uniqueKeysWithValues: VoiceProvider.allCases.map { ($0, SettingsCredential($0)) })
    subscript(_ provider: VoiceProvider) -> SettingsCredential { entries[provider]! }
}
