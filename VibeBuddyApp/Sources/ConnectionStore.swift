import Foundation
import CryptoKit
import VibeBuddyKit

/// Persists the pairing (host/port/token) so the app reconnects automatically.
/// v1 uses UserDefaults; Keychain hardening is a later step.
@MainActor
final class ConnectionStore: ObservableObject {
    @Published private(set) var pairing: PairingPayload?
    /// Demo mode: show the dashboard populated with sample data and no network,
    /// so the app is reviewable (and explorable) without a paired Mac.
    @Published private(set) var demo = false

    private let defaults = UserDefaults.standard
    private let key = "vibebuddy.pairing"

    init() {
        if ProcessInfo.processInfo.environment["VIBEBUDDY_DEMO"] == "1" {
            demo = true
        } else if let fromEnvironment = Self.environmentPairing() {
            pairing = fromEnvironment
            Self.observePairing(fromEnvironment)
        } else if let data = defaults.data(forKey: key),
           let saved = try? JSONDecoder().decode(PairingPayload.self, from: data) {
            pairing = saved
            Self.observePairing(saved)
        }
    }

    /// Optional config via env (VIBEBUDDY_HOST/PORT/TOKEN) — for the Simulator,
    /// and for pointing a device build at a second Mac instance from
    /// `devicectl` during acceptance. It wins over the saved pairing for that
    /// launch only and is never saved; only a developer tool can set it.
    static func environmentPairing() -> PairingPayload? {
        let env = ProcessInfo.processInfo.environment
        guard let host = env["VIBEBUDDY_HOST"],
              let port = env["VIBEBUDDY_PORT"].flatMap(Int.init),
              let token = env["VIBEBUDDY_TOKEN"] else { return nil }
        return PairingPayload(host: host, port: port, token: token)
    }

    static var pairingEpoch: String {
        if let value = UserDefaults.standard.string(forKey: "vibebuddy.pairingEpoch") { return value }
        return rotateEpoch()
    }
    @discardableResult
    static func rotateEpoch() -> String {
        let value = UUID().uuidString
        UserDefaults.standard.set(value, forKey: "vibebuddy.pairingEpoch")
        return value
    }

    /// Persist only a digest here, so env-based reconnects detect a changed
    /// authority without storing another copy of its credential.
    static func observePairing(_ payload: PairingPayload) {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(payload) else { return }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let key = "vibebuddy.pairingFingerprint"
        if UserDefaults.standard.string(forKey: key) != digest {
            rotateEpoch()
            UserDefaults.standard.set(digest, forKey: key)
        }
    }

    /// Monotonic across process restarts and all pairing epochs. A wall clock
    /// seed also prevents a fresh simulator install from reusing tiny revisions.
    static func nextRelayRevision() -> UInt64 {
        let key = "vibebuddy.watchRelayRevision"
        let previous = UInt64(UserDefaults.standard.string(forKey: key) ?? "0") ?? 0
        let next = max(previous + 1, UInt64(max(0, Date().timeIntervalSince1970) * 1_000_000))
        UserDefaults.standard.set(String(next), forKey: key)
        return next
    }

    func save(_ payload: PairingPayload) {
        Self.observePairing(payload)
        pairing = payload
        if let data = try? JSONEncoder().encode(payload) {
            defaults.set(data, forKey: key)
        }
    }

    func enterDemo() { demo = true }

    func clear() {
        Self.rotateEpoch()
        pairing = nil
        demo = false
        defaults.removeObject(forKey: key)
        defaults.removeObject(forKey: "vibebuddy.pairingFingerprint")
    }
}
