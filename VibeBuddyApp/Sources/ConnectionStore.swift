import Foundation
import CryptoKit
import UIKit
import VibeBuddyKit

/// Persists the pairing (host/port/token) so the app reconnects automatically.
/// v1 uses UserDefaults; Keychain hardening is a later step.
@MainActor
final class ConnectionStore: ObservableObject {
    /// Why `pairing` is nil although this phone is not a fresh install. A phone
    /// that has genuinely never paired leaves this nil; anything else means
    /// there are bytes on disk that no screen may delete on its own.
    enum LoadFailure: Equatable {
        /// Something is stored under the key and it is not a pairing we can read.
        case unreadable
        /// The read ran while the app's defaults were still protected — a
        /// background launch before the first unlock answers for nothing.
        case protectedDataUnavailable
    }

    @Published private(set) var pairing: PairingPayload?
    /// Demo mode: show the dashboard populated with sample data and no network,
    /// so the app is reviewable (and explorable) without a paired Mac.
    @Published private(set) var demo = false
    /// Set when a load came back empty for a reason that is not "unpaired".
    /// The connect screen offers a retry instead of presenting the phone as new.
    @Published private(set) var loadFailure: LoadFailure?

    @Published private(set) var directPairing: PairingPayload?
    @Published private(set) var cloudflarePairing: PairingPayload?
    private(set) var verifiedSourceID: String?
    private(set) var revision = 0
    private struct Routes: Codable {
        var direct: PairingPayload
        var cloudflare: PairingPayload
        var sourceID: String
    }
    private let routesKey = "vibebuddy.connectionRoutes"
    private let defaults: UserDefaults
    private let protectedDataAvailable: @MainActor () -> Bool
    private let deleteCredential: (String) throws -> Void
    private let key = "vibebuddy.pairing"

    init(defaults: UserDefaults = .standard,
         protectedDataAvailable: @escaping @MainActor () -> Bool = { UIApplication.shared.isProtectedDataAvailable },
         deleteCredential: @escaping (String) throws -> Void = { try CloudflareCredentialStore.delete(id: $0) }) {
        self.defaults = defaults
        self.protectedDataAvailable = protectedDataAvailable
        self.deleteCredential = deleteCredential
        if ProcessInfo.processInfo.environment["VIBEBUDDY_DEMO"] == "1" {
            demo = true
        } else if let fromEnvironment = Self.environmentPairing() {
            pairing = fromEnvironment
            Self.observePairing(fromEnvironment)
        } else {
            load()
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

    /// Read the saved pairing. It never deletes and never overwrites: bytes
    /// that will not decode, and an empty read taken while the defaults were
    /// still protected, are recorded as a failure rather than mistaken for a
    /// phone that has no Mac.
    private func load() {
        guard pairing == nil, !demo else { return }
        guard let data = defaults.data(forKey: key) else {
            loadFailure = protectedDataAvailable() ? nil : .protectedDataUnavailable
            return
        }
        guard let saved = try? JSONDecoder().decode(PairingPayload.self, from: data) else {
            loadFailure = .unreadable
            return
        }
        pairing = saved
        if let bytes = defaults.data(forKey: routesKey),
           let routes = try? JSONDecoder().decode(Routes.self, from: bytes),
           routes.direct.isValidConnection, !routes.direct.isCloudflare,
           routes.cloudflare.isValidConnection, routes.cloudflare.isCloudflare,
           routes.direct.token == routes.cloudflare.token, !routes.sourceID.isEmpty,
           saved == routes.direct || saved == routes.cloudflare {
            directPairing = routes.direct
            cloudflarePairing = routes.cloudflare
            verifiedSourceID = routes.sourceID
        } else if !saved.isCloudflare {
            directPairing = saved
        }
        loadFailure = nil
        Self.observePairing(saved)
    }

    /// Read the saved pairing again after a launch that could not see it.
    /// The store reads once, when the scene builds it, and a launch into the
    /// background — a banner's Approve/Deny/Reply, or an island button, both
    /// of which run without bringing the app forward — can happen before the
    /// device has been unlocked since it booted, when the app's defaults
    /// answer for nothing. Without this the process would go on presenting an
    /// unpaired phone for as long as it lives, with the Mac still on disk.
    func reloadSavedPairing() {
        guard pairing == nil, !demo, Self.environmentPairing() == nil else { return }
        load()
    }

    @discardableResult
    func save(_ payload: PairingPayload) -> Bool {
        guard payload.isValidConnection else { return false }
        // New scans and Mac address updates are direct pairings only. Access
        // references are local records and cannot arrive through a QR code.
        guard !payload.isCloudflare else { return false }
        do { try discardCloudflare() } catch { return false }
        directPairing = payload
        persist(payload)
        return true
    }

    /// An authenticated address update for this same Mac may refresh the
    /// saved direct route without deleting the independently configured route.
    @discardableResult
    func saveVerifiedDirect(_ payload: PairingPayload, sourceID: String?) -> Bool {
        guard payload.isValidConnection, !payload.isCloudflare else { return false }
        // An address-only update cannot prove it is the same Mac without identity.
        // Keep both routes and the secret untouched; explicit re-pairing uses save.
        if cloudflarePairing != nil, payload.token == cloudflarePairing?.token,
           sourceID?.isEmpty != false { return false }
        guard let sourceID, let cloudflarePairing, verifiedSourceID == sourceID,
              cloudflarePairing.token == payload.token else { return save(payload) }
        directPairing = payload
        if let data = try? JSONEncoder().encode(Routes(direct: payload, cloudflare: cloudflarePairing, sourceID: sourceID)) {
            defaults.set(data, forKey: routesKey)
        }
        persist(payload)
        return true
    }

    private func persist(_ payload: PairingPayload) {
        revision += 1
        Self.observePairing(payload)
        demo = false
        loadFailure = nil
        pairing = payload
        if let data = try? JSONEncoder().encode(payload) {
            defaults.set(data, forKey: key)
        }
    }

    @discardableResult
    func commitCloudflare(_ payload: PairingPayload, sourceID: String) -> Bool {
        guard payload.isValidConnection, payload.isCloudflare, !sourceID.isEmpty,
              let direct = directPairing ?? pairing, !direct.isCloudflare else { return false }
        let previous = cloudflarePairing?.cloudflareCredentialID
        if let previous, previous != payload.cloudflareCredentialID {
            do { try deleteCredential(previous) } catch { return false }
        }
        directPairing = direct
        cloudflarePairing = payload
        verifiedSourceID = sourceID
        if let data = try? JSONEncoder().encode(Routes(direct: direct, cloudflare: payload, sourceID: sourceID)) {
            defaults.set(data, forKey: routesKey)
        }
        persist(payload)
        return true
    }

    func selectDirect() {
        guard let directPairing else { return }
        persist(directPairing)
    }

    func selectCloudflare() {
        guard let cloudflarePairing else { return }
        persist(cloudflarePairing)
    }

    @discardableResult
    func removeCloudflare() -> Bool {
        let wasCloudflare = pairing?.isCloudflare == true
        guard !wasCloudflare || directPairing != nil else { return false }
        do { try discardCloudflare() } catch { return false }
        if wasCloudflare { selectDirect() }
        revision += 1
        return true
    }

    private func discardCloudflare() throws {
        if let id = cloudflarePairing?.cloudflareCredentialID ?? pairing?.cloudflareCredentialID {
            try deleteCredential(id)
        }
        cloudflarePairing = nil
        verifiedSourceID = nil
        defaults.removeObject(forKey: routesKey)
    }

    func enterDemo() { demo = true }

    /// Leave the demo without touching the saved pairing. Exiting sample data
    /// is not a request to forget a Mac, and the demo is reachable from the
    /// connect screen — which is also where a phone lands when its saved
    /// pairing could not be read.
    func exitDemo() {
        demo = false
        load()
    }

    /// Forget the Mac: it leaves memory and disk. Only a confirmed
    /// "Disconnect" reaches this. Nothing may call it to tidy up a screen that
    /// merely looks unpaired — the pairing it would delete may be one this
    /// process failed to read.
    @discardableResult
    func clear() -> Bool {
        do { try discardCloudflare() } catch { return false }
        directPairing = nil
        revision += 1
        Self.rotateEpoch()
        pairing = nil
        demo = false
        loadFailure = nil
        defaults.removeObject(forKey: key)
        defaults.removeObject(forKey: "vibebuddy.pairingFingerprint")
        return true
    }
}
