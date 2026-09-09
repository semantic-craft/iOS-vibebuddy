import Foundation
import Security
import Testing
@testable import VibeBuddyKit

@Suite("Keychain presence without decryption")
struct KeychainPresenceTests {
    @Test func asksForAttributesOnlySoItCannotPrompt() {
        var seen: [String: Any] = [:]
        let found = KeychainStore.exists("openai.apiKey") { query in
            seen = query
            return errSecSuccess
        }
        #expect(found)
        // Returning the data is what consults the item's access control; a page
        // that only reports "key saved" must never ask for it.
        #expect(seen[kSecReturnData as String] == nil)
        #expect(seen[kSecAttrAccount as String] as? String == "openai.apiKey")
    }

    @Test func missingOrUnreadableIsNotPresent() {
        #expect(!KeychainStore.exists("openai.apiKey") { _ in errSecItemNotFound })
        #expect(!KeychainStore.exists("openai.apiKey") { _ in errSecAuthFailed })
    }
}
