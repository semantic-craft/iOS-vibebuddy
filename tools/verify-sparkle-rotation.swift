import Foundation
import Security
import CryptoKit

// Mirrors the Security.framework requirement check used by Sparkle 2.9.6
// SUCodeSigningVerifier and verifies the new archive against its embedded EdDSA key.
let args = CommandLine.arguments
precondition(args.count == 5, "old.app new.app archive signature")
func fail(_ message: String) -> Never { fputs(message + "\n", stderr); exit(1) }
func bundleInfo(_ path: String) throws -> [String: Any] {
    let data = try Data(contentsOf: URL(fileURLWithPath: path).appendingPathComponent("Contents/Info.plist"))
    return try PropertyListSerialization.propertyList(from: data, format: nil) as! [String: Any]
}
func code(_ path: String) -> SecStaticCode {
    var result: SecStaticCode?
    let status = SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &result)
    guard status == errSecSuccess, let result else { fail("Cannot load signed bundle: \(status)") }
    return result
}
let old = code(args[1]), new = code(args[2])
var requirement: SecRequirement?
let copied = SecCodeCopyDesignatedRequirement(old, [], &requirement)
guard copied == errSecSuccess, let requirement else { fail("Cannot load old designated requirement") }
var error: Unmanaged<CFError>?
let valid = SecStaticCodeCheckValidityWithErrors(new, SecCSFlags(rawValue: kSecCSCheckAllArchitectures), requirement, &error)
guard valid == errSecSuccess else { fail("New app fails old signing requirement: \(valid) \(String(describing: error?.takeRetainedValue()))") }
let oldInfo = try bundleInfo(args[1]), newInfo = try bundleInfo(args[2])
guard oldInfo["CFBundleIdentifier"] as? String == newInfo["CFBundleIdentifier"] as? String else { fail("Bundle identifier changed") }
guard let oldKey = oldInfo["SUPublicEDKey"] as? String, let newKey = newInfo["SUPublicEDKey"] as? String,
      let newData = Data(base64Encoded: newKey), let oldData = Data(base64Encoded: oldKey),
      let signature = Data(base64Encoded: args[4]) else { fail("Missing key/signature") }
let archive = try Data(contentsOf: URL(fileURLWithPath: args[3]))
let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: newData)
guard publicKey.isValidSignature(signature, for: archive) else { fail("Archive fails new embedded EdDSA key") }
let oldPublicKey = try Curve25519.Signing.PublicKey(rawRepresentation: oldData)
let report: [String: Any] = [
    "old_version": oldInfo["CFBundleShortVersionString"] ?? "unknown",
    "same_bundle_id": true,
    "old_designated_requirement_accepts_new_app": true,
    "new_embedded_key_accepts_archive": true,
    "old_key_accepts_archive": oldPublicKey.isValidSignature(signature, for: archive),
    "key_rotated": oldKey != newKey,
    "old_requires_signed_feed": oldInfo["SURequireSignedFeed"] as? Bool ?? false,
    "old_requires_pre_extraction_validation": oldInfo["SUVerifyUpdateBeforeExtraction"] as? Bool ?? false,
    "scope": "Cryptographic rotation validation; does not install an update or exercise updater UI"
]
print(String(data: try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]), encoding: .utf8)!)
