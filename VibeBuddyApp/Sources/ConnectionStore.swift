import Foundation
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
        } else if let data = defaults.data(forKey: key),
           let saved = try? JSONDecoder().decode(PairingPayload.self, from: data) {
            pairing = saved
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

    func save(_ payload: PairingPayload) {
        pairing = payload
        if let data = try? JSONEncoder().encode(payload) {
            defaults.set(data, forKey: key)
        }
    }

    func enterDemo() { demo = true }

    func clear() {
        pairing = nil
        demo = false
        defaults.removeObject(forKey: key)
    }
}
