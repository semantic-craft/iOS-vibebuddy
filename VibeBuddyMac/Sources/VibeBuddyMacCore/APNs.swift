import Foundation
import VibeBuddyKit

/// APNs provider config. Filled from env once the user has a paid account +
/// an APNs auth key (.p8). Returns nil until configured, so push stays off.
public struct APNsConfig: Sendable {
    public let teamID: String
    public let keyID: String
    public let bundleID: String
    public let p8PEM: String
    public let useSandbox: Bool

    public var host: String { useSandbox ? "api.sandbox.push.apple.com" : "api.push.apple.com" }

    public init(teamID: String, keyID: String, bundleID: String, p8PEM: String, useSandbox: Bool) {
        self.teamID = teamID; self.keyID = keyID; self.bundleID = bundleID
        self.p8PEM = p8PEM; self.useSandbox = useSandbox
    }

    /// Env first (CLI), then the config file (GUI apps don't inherit shell env).
    public static func load() -> APNsConfig? {
        fromEnvironment() ?? fromFile()
    }

    /// APNS_TEAM_ID / APNS_KEY_ID / APNS_BUNDLE_ID / APNS_KEY_PATH (+ APNS_SANDBOX=1).
    public static func fromEnvironment() -> APNsConfig? {
        let e = ProcessInfo.processInfo.environment
        guard let team = e["APNS_TEAM_ID"], let key = e["APNS_KEY_ID"],
              let bundle = e["APNS_BUNDLE_ID"], let path = e["APNS_KEY_PATH"],
              let pem = try? String(contentsOfFile: path, encoding: .utf8)
        else { return nil }
        return APNsConfig(teamID: team, keyID: key, bundleID: bundle, p8PEM: pem,
                          useSandbox: e["APNS_SANDBOX"] == "1")
    }

    /// ~/Library/Application Support/vibebuddy/apns.json
    public static func fromFile() -> APNsConfig? {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let url = base.appendingPathComponent("vibebuddy/apns.json")
        guard let data = try? Data(contentsOf: url),
              let cfg = try? JSONDecoder().decode(FileConfig.self, from: data),
              let pem = try? String(contentsOfFile: cfg.keyPath, encoding: .utf8)
        else { return nil }
        return APNsConfig(teamID: cfg.teamID, keyID: cfg.keyID, bundleID: cfg.bundleID,
                          p8PEM: pem, useSandbox: cfg.sandbox)
    }

    private struct FileConfig: Decodable {
        let teamID: String, keyID: String, bundleID: String, keyPath: String, sandbox: Bool
    }
}

/// Registered iOS devices (uploaded by the app via POST /device), keyed by APNs
/// token, with the phone's sound preferences so the Mac's push respects them.
public actor DeviceTokens {
    private var devicesByToken: [String: DeviceRegistrationPayload] = [:]
    public init() {}

    public func add(_ token: String) {
        if devicesByToken[token] == nil { devicesByToken[token] = DeviceRegistrationPayload(token: token) }
    }

    /// Upsert a device, merging in any preference fields the payload carries.
    public func register(_ payload: DeviceRegistrationPayload) {
        guard let token = payload.token, !token.isEmpty else { return }
        var merged = devicesByToken[token] ?? DeviceRegistrationPayload(token: token)
        merged.token = token
        if let v = payload.name { merged.name = v }
        if let v = payload.model { merged.model = v }
        if let v = payload.systemVersion { merged.systemVersion = v }
        if let v = payload.playSound { merged.playSound = v }
        if let v = payload.quietMode { merged.quietMode = v }
        devicesByToken[token] = merged
    }

    public func all() -> [String] { Array(devicesByToken.keys) }
    public func devices() -> [DeviceRegistrationPayload] { Array(devicesByToken.values) }
}

/// Sends "needs you" alerts to registered devices over APNs (HTTP/2 + cached
/// ES256 JWT). No-op-safe: failures are swallowed so monitoring never breaks.
public actor APNsPusher {
    private let config: APNsConfig
    private let jwt: APNsJWT
    private var cached: (token: String, issued: Date)?

    public init(config: APNsConfig) throws {
        self.config = config
        self.jwt = try APNsJWT(teamID: config.teamID, keyID: config.keyID, p8PEM: config.p8PEM)
    }

    /// `sound` is a bundled CAF file name (e.g. `needs_approval.caf`) so the
    /// background alert matches the in-app sound pack; defaults to the system sound.
    public func send(title: String, body: String, to deviceToken: String,
                     sound: String = "default", now: Date = Date()) async {
        guard let url = URL(string: "https://\(config.host)/3/device/\(deviceToken)"),
              let auth = try? providerToken(now: now) else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("bearer \(auth)", forHTTPHeaderField: "authorization")
        request.setValue(config.bundleID, forHTTPHeaderField: "apns-topic")
        request.setValue("alert", forHTTPHeaderField: "apns-push-type")
        request.setValue("10", forHTTPHeaderField: "apns-priority")
        // An empty sound means a silent (banner-only) push.
        let soundField = sound.isEmpty ? "" : #","sound":"\#(escape(sound))""#
        let payload = #"{"aps":{"alert":{"title":"\#(escape(title))","body":"\#(escape(body))"}\#(soundField)}}"#
        request.httpBody = Data(payload.utf8)
        _ = try? await URLSession.shared.data(for: request)
    }

    private func providerToken(now: Date) throws -> String {
        if let cached, now.timeIntervalSince(cached.issued) < 3000 { return cached.token }
        let token = try jwt.token(now: now)
        cached = (token, now)
        return token
    }

    private nonisolated func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
         .replacingOccurrences(of: "\n", with: " ")
    }
}
