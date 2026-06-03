import Foundation
import VibeBuddyKit

/// Persists the pairing (host/port/token) so the app reconnects automatically.
/// v1 uses UserDefaults; Keychain hardening is a later step.
@MainActor
final class ConnectionStore: ObservableObject {
    @Published private(set) var pairing: PairingPayload?

    private let defaults = UserDefaults.standard
    private let key = "vibebuddy.pairing"

    init() {
        if let data = defaults.data(forKey: key),
           let saved = try? JSONDecoder().decode(PairingPayload.self, from: data) {
            pairing = saved
        } else {
            pairing = Self.environmentPairing()
        }
    }

    /// Optional config via env (VIBEBUDDY_HOST/PORT/TOKEN) — handy for the
    /// Simulator and power users; ignored when a saved pairing exists.
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

    func clear() {
        pairing = nil
        defaults.removeObject(forKey: key)
    }
}
