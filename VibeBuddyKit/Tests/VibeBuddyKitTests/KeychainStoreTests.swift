import Foundation
import Security
import Testing
@testable import VibeBuddyKit

@Suite("KeychainStore write safety")
struct KeychainStoreTests {
    @Test("failed update preserves the previous secret")
    func failedUpdatePreservesPrevious() {
        let account = "test.account.issue114"
        let fake = FakeKeychain([account: Data("previous-secret".utf8)])
        fake.updateResult = errSecAuthFailed

        let status = KeychainStore.set("replacement", for: account, operations: fake.operations)
        #expect(status == errSecAuthFailed)
        #expect(fake.updateCalls == 1)
        #expect(fake.addCalls == 0)
        #expect(fake.deleteCalls == 0)
        #expect(String(data: fake.store[account]!, encoding: .utf8) == "previous-secret")
        #expect(KeychainStore.get(account, operations: fake.operations) == "previous-secret")
    }

    @Test("update-or-add writes when the item is missing")
    func addWhenMissing() {
        let account = "test.account.issue114.missing"
        let fake = FakeKeychain()
        fake.updateResult = errSecItemNotFound

        #expect(KeychainStore.set("fresh", for: account, operations: fake.operations) == errSecSuccess)
        #expect(KeychainStore.get(account, operations: fake.operations) == "fresh")
        #expect(fake.addCalls == 1)
    }
}

/// In-memory Keychain stand-in. `@unchecked Sendable` so tests can inject it
/// into `@Sendable` operation closures without touching the real Keychain.
private final class FakeKeychain: @unchecked Sendable {
    var store: [String: Data]
    var updateResult: OSStatus = errSecSuccess
    var updateCalls = 0
    var addCalls = 0
    var deleteCalls = 0

    init(_ store: [String: Data] = [:]) {
        self.store = store
    }

    var operations: KeychainStore.Operations {
        KeychainStore.Operations(
            update: { [self] query, attributes in
                self.updateCalls += 1
                if self.updateResult != errSecSuccess {
                    return self.updateResult
                }
                let key = query[kSecAttrAccount as String] as? String ?? ""
                guard self.store[key] != nil else { return errSecItemNotFound }
                if let data = attributes[kSecValueData as String] as? Data {
                    self.store[key] = data
                }
                return errSecSuccess
            },
            add: { [self] item in
                self.addCalls += 1
                let key = item[kSecAttrAccount as String] as? String ?? ""
                let data = item[kSecValueData as String] as? Data ?? Data()
                self.store[key] = data
                return errSecSuccess
            },
            delete: { [self] query in
                self.deleteCalls += 1
                let key = query[kSecAttrAccount as String] as? String ?? ""
                self.store.removeValue(forKey: key)
                return errSecSuccess
            },
            copyMatching: { [self] query in
                let key = query[kSecAttrAccount as String] as? String ?? ""
                if let data = self.store[key] {
                    return (errSecSuccess, data)
                }
                return (errSecItemNotFound, nil)
            }
        )
    }
}
