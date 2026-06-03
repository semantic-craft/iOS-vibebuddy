import Testing
import Foundation
import Crypto
@testable import VibeBuddyMacCore

@Suite("APNsJWT — ES256 provider token")
struct APNsJWTTests {

    private func base64URLDecode(_ s: String) -> Data {
        var t = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while t.count % 4 != 0 { t += "=" }
        return Data(base64Encoded: t) ?? Data()
    }
    private func json(_ part: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: base64URLDecode(part))) as? [String: Any] ?? [:]
    }

    @Test("produces a 3-part JWT with the right header, claims, and a verifiable signature")
    func roundTrip() throws {
        let key = P256.Signing.PrivateKey()
        let jwt = try APNsJWT(teamID: "TEAM123456", keyID: "KEY7890AB",
                              p8PEM: key.pemRepresentation)
        let token = try jwt.token(now: Date(timeIntervalSince1970: 1_700_000_000))

        let parts = token.split(separator: ".").map(String.init)
        #expect(parts.count == 3)

        let header = json(parts[0])
        #expect(header["alg"] as? String == "ES256")
        #expect(header["kid"] as? String == "KEY7890AB")

        let payload = json(parts[1])
        #expect(payload["iss"] as? String == "TEAM123456")
        #expect(payload["iat"] as? Int == 1_700_000_000)

        let signingInput = "\(parts[0]).\(parts[1])"
        let signature = try P256.Signing.ECDSASignature(rawRepresentation: base64URLDecode(parts[2]))
        #expect(key.publicKey.isValidSignature(signature, for: Data(signingInput.utf8)))
    }

    @Test("rejects a malformed PEM")
    func badPEM() {
        #expect(throws: (any Error).self) {
            _ = try APNsJWT(teamID: "T", keyID: "K", p8PEM: "not a key")
        }
    }
}
