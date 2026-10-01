import Foundation
import VibeBuddyKit

@main
struct SettingsCredentialsRegression {
    @MainActor static func main() {
        var stored: String? = "saved-test-key"
        var writes = 0
        var fail = false
        var accounts: [String] = []
        let credential = SettingsCredential(.qwen, storage: .init(
            exists: { _ in stored != nil },
            read: { _ in stored },
            write: { value, account in
                writes += 1
                accounts.append(account)
                guard !fail else { return false }
                stored = value
                return true
            }))

        credential.load()
        credential.beginEditing()
        credential.edit("cancelled-draft")
        credential.load()
        precondition(credential.value == "saved-test-key", "Tests must read the saved value")
        credential.cancel()
        precondition(stored == "saved-test-key" && writes == 0 && credential.draft.isEmpty)
        precondition(credential.revision == 0)

        credential.beginEditing()
        credential.edit("  ")
        precondition(!credential.canSave && !credential.save() && writes == 0)
        credential.edit("replacement-test-key")
        fail = true
        precondition(!credential.save())
        precondition(credential.saveFailed && credential.draft == "replacement-test-key")
        precondition(stored == "saved-test-key" && credential.value == stored && credential.configured)
        precondition(credential.revision == 0 && credential.editing)
        fail = false
        precondition(credential.save())
        precondition(stored == "replacement-test-key" && credential.value == stored)
        precondition(credential.revision == 1 && !credential.editing && credential.draft.isEmpty)

        credential.beginEditing()
        fail = true
        precondition(!credential.remove() && credential.removalFailed)
        precondition(stored == "replacement-test-key" && credential.configured && credential.revision == 1)
        fail = false
        precondition(credential.remove())
        precondition(stored == nil && !credential.configured && credential.revision == 2)
        precondition(accounts.allSatisfy { $0 == VoiceProvider.qwen.keychainAccount })
        print("PASS: draft cancellation, saved-only reads, empty draft, failed save/retry, explicit removal and stable account")
    }
}
