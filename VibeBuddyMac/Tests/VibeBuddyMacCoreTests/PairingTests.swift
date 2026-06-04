import Testing
import Foundation
import VibeBuddyKit
@testable import VibeBuddyMacCore

@Suite("Pairing, token, and LAN address")
struct PairingTests {

    @Test("generated token is 32 lowercase hex chars and random")
    func tokenFormat() {
        let t = Token.generate()
        #expect(t.count == 32)
        #expect(t.allSatisfy { "0123456789abcdef".contains($0) })
        #expect(Token.generate() != Token.generate())
    }

    @Test("TokenStore creates once, then returns the same token")
    func tokenStore() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory() + "vb-token-\(UUID().uuidString)")
        let url = dir.appendingPathComponent("token")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = TokenStore(fileURL: url)
        let a = try store.loadOrCreate()
        let b = try store.loadOrCreate()
        #expect(a == b)
        #expect(a.count == 32)
    }

    @Test("TokenStore writes the token file owner-only (0600)")
    func tokenStorePermissions() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory() + "vb-token-\(UUID().uuidString)")
        let url = dir.appendingPathComponent("token")
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try TokenStore(fileURL: url).loadOrCreate()
        let perms = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        #expect(perms == 0o600)
    }

    @Test("LAN picker prefers en*, skips loopback and link-local")
    func lanPick() {
        #expect(LANAddress.pick(from: [("lo0", "127.0.0.1"), ("en0", "192.168.1.20")]) == "192.168.1.20")
        #expect(LANAddress.pick(from: [("utun0", "10.0.0.1"), ("en0", "192.168.1.5")]) == "192.168.1.5")
        #expect(LANAddress.pick(from: [("en5", "169.254.1.1"), ("bridge0", "10.1.1.1")]) == "10.1.1.1")
        #expect(LANAddress.pick(from: [("lo0", "127.0.0.1")]) == nil)
    }

    @Test("pairing QR JSON round-trips to PairingPayload")
    func qrJSON() throws {
        let payload = PairingPayload(host: "192.168.1.20", port: 9876, token: "abc123")
        let json = Pairing.qrJSONString(for: payload)
        let decoded = try JSONDecoder().decode(PairingPayload.self, from: Data(json.utf8))
        #expect(decoded == payload)
    }

    @Test("a QR image is generated from a string")
    func qrImage() {
        #expect(Pairing.qrImage(from: "vibebuddy://pair") != nil)
    }
}
