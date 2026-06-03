import Foundation
import Crypto

/// Builds the APNs provider authentication token (JWT, ES256) from an Apple .p8
/// key (a PKCS#8 PEM). The token stays valid ~1h; callers cache it. swift-crypto
/// accepts both SEC1 and PKCS#8 PEM, so real .p8 keys parse directly.
struct APNsJWT {
    let teamID: String
    let keyID: String
    private let privateKey: P256.Signing.PrivateKey

    init(teamID: String, keyID: String, p8PEM: String) throws {
        self.teamID = teamID
        self.keyID = keyID
        self.privateKey = try P256.Signing.PrivateKey(pemRepresentation: p8PEM)
    }

    func token(now: Date) throws -> String {
        let header = #"{"alg":"ES256","kid":"\#(keyID)"}"#
        let claims = #"{"iss":"\#(teamID)","iat":\#(Int(now.timeIntervalSince1970))}"#
        let signingInput = Self.base64URL(Data(header.utf8)) + "." + Self.base64URL(Data(claims.utf8))
        let signature = try privateKey.signature(for: Data(signingInput.utf8))
        return signingInput + "." + Self.base64URL(signature.rawRepresentation)
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
