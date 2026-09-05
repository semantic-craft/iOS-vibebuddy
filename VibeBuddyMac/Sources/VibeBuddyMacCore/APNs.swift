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
        if let v = payload.categories { merged.categories = v }
        devicesByToken[token] = merged
    }

    public func all() -> [String] { Array(devicesByToken.keys) }
    public func devices() -> [DeviceRegistrationPayload] { Array(devicesByToken.values) }
}

/// The phone's string-table keys for a push, so the banner reads in the
/// phone's language. See `PushCopy`.
public struct PushLocalization: Equatable, Sendable {
    public var titleKey: String
    public var titleArgs: [String]
    public var bodyKey: String?
    public init(titleKey: String, titleArgs: [String], bodyKey: String?) {
        self.titleKey = titleKey
        self.titleArgs = titleArgs
        self.bodyKey = bodyKey
    }
    public init(_ copy: PushCopy) {
        self.init(titleKey: copy.titleKey, titleArgs: copy.titleArgs, bodyKey: copy.bodyKey)
    }
}

/// Sends "needs you" alerts to registered devices over APNs (HTTP/2 + cached
/// ES256 JWT). Failures are recorded as `failed`; 2xx is `accepted` by Apple.
public actor APNsPusher {
    private let config: APNsConfig
    private let jwt: APNsJWT
    private let http: any APNsHTTPClient
    private let recorder: (any NotificationDeliveryRecording)?
    private var cached: (token: String, issued: Date)?

    public init(
        config: APNsConfig,
        http: any APNsHTTPClient = URLSession.shared,
        recorder: (any NotificationDeliveryRecording)? = nil
    ) throws {
        self.config = config
        self.http = http
        self.recorder = recorder
        self.jwt = try APNsJWT(teamID: config.teamID, keyID: config.keyID, p8PEM: config.p8PEM)
    }

    /// `sound` is a bundled CAF file name (e.g. `needs_approval.caf`) so the
    /// background alert matches the in-app sound pack; defaults to the system sound.
    /// 2xx is `accepted` by Apple's servers — not proof the device showed a banner.
    @discardableResult
    public func send(title: String, body: String, to deviceToken: String,
                     sound: String = "default", now: Date = Date(),
                     sessionID: String? = nil,
                     soundCategory: String? = nil,
                     localized: PushLocalization? = nil) async -> APNsSendResult {
        let category = soundCategory ?? sound.replacingOccurrences(of: ".caf", with: "")
        guard let url = URL(string: "https://\(config.host)/3/device/\(deviceToken)"),
              let auth = try? providerToken(now: now) else {
            return await finish(
                APNsDelivery.classify(status: nil, error: SendFailure.unreachable),
                status: nil, now: now, sessionID: sessionID, sound: category)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("bearer \(auth)", forHTTPHeaderField: "authorization")
        request.setValue(config.bundleID, forHTTPHeaderField: "apns-topic")
        request.setValue("alert", forHTTPHeaderField: "apns-push-type")
        request.setValue("10", forHTTPHeaderField: "apns-priority")
        // The same identifier the phone gives its own local notification for
        // this cue, so the two channels collapse into one banner instead of
        // saying the same thing twice — once on the phone, twice on the Watch.
        if let sessionID, let sound = NotificationSound(rawValue: category) {
            request.setValue(NotificationIdentity.id(sessionID: sessionID, sound: sound),
                             forHTTPHeaderField: "apns-collapse-id")
        }
        request.httpBody = Data(Self.alertPayload(title: title, body: body, sound: sound,
                                                  sessionID: sessionID, localized: localized).utf8)
        do {
            let (_, response) = try await http.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode
            return await finish(
                APNsDelivery.classify(status: status, error: nil),
                status: status, now: now, sessionID: sessionID, sound: category)
        } catch {
            return await finish(
                APNsDelivery.classify(status: nil, error: error),
                status: nil, now: now, sessionID: sessionID, sound: category)
        }
    }

    /// Record a cue that was earned but sent to nobody. Not a send, so it never
    /// goes near APNs — but it is the only trace that cue leaves on this channel,
    /// so it belongs with the sends rather than in a caller's own bookkeeping.
    public func recordSkip(sessionID: String?, sound: NotificationSound,
                           reason: CueSkipReason, now: Date = Date()) async {
        await recorder?.record(NotificationDeliveryRecord(
            channel: .apns, outcome: .skipped, sessionID: sessionID,
            sound: sound.rawValue, failureReason: reason.rawValue, timestamp: now))
    }

    /// The `alert` push body. An empty sound means a silent (banner-only) push.
    /// The session id rides outside `aps` so the phone's `userInfo["sessionId"]`
    /// reads the same for a push as for its own local notification, and a tapped
    /// banner can open the session either way. It also goes in as `thread-id`,
    /// the phone's `threadIdentifier` for the same session, so the push files
    /// into that session's group instead of the app-wide stack.
    /// `localized` adds the phone's string-table keys next to the English
    /// copy so the banner reads in the phone's language.
    nonisolated static func alertPayload(title: String, body: String, sound: String,
                                         sessionID: String?,
                                         localized: PushLocalization? = nil) -> String {
        var alert = #""title":"\#(escape(title))","body":"\#(escape(body))""#
        if let localized {
            let args = localized.titleArgs.map { #""\#(escape($0))""# }.joined(separator: ",")
            alert += #","title-loc-key":"\#(escape(localized.titleKey))","title-loc-args":[\#(args)]"#
            if let bodyKey = localized.bodyKey {
                alert += #","loc-key":"\#(escape(bodyKey))""#
            }
        }
        let soundField = sound.isEmpty ? "" : #","sound":"\#(escape(sound))""#
        let threadField = sessionID.map { #","thread-id":"\#(escape($0))""# } ?? ""
        let sessionField = sessionID.map { #","sessionId":"\#(escape($0))""# } ?? ""
        return #"{"aps":{"alert":{\#(alert)}\#(soundField)\#(threadField)}\#(sessionField)}"#
    }

    private func finish(
        _ classified: NotificationDeliveryClassification,
        status: Int?,
        now: Date,
        sessionID: String?,
        sound: String?
    ) async -> APNsSendResult {
        let result = APNsSendResult(
            outcome: classified.outcome, status: status, failureReason: classified.failureReason)
        await recorder?.record(NotificationDeliveryRecord(
            channel: .apns,
            outcome: classified.outcome,
            sessionID: sessionID,
            sound: sound,
            failureReason: classified.failureReason,
            timestamp: now
        ))
        return result
    }

    private enum SendFailure: Error { case unreachable }

    /// Push a Live Activity content-state update (`dynamic-island/02`). Unlike `send`
    /// (an `alert` push to a *device* token), this is an `apns-push-type: liveactivity`
    /// push to a per-activity push token, on the `…push-type.liveactivity` topic.
    public func sendActivityUpdate(summary: TaskPresentationSummary,
                                   topProject: String?, topSessionId: String?,
                                   to activityToken: String, now: Date = Date()) async {
        guard let url = URL(string: "https://\(config.host)/3/device/\(activityToken)"),
              let auth = try? providerToken(now: now) else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("bearer \(auth)", forHTTPHeaderField: "authorization")
        request.setValue("\(config.bundleID).push-type.liveactivity", forHTTPHeaderField: "apns-topic")
        request.setValue("liveactivity", forHTTPHeaderField: "apns-push-type")
        request.setValue("10", forHTTPHeaderField: "apns-priority")
        request.httpBody = Data(Self.activityPayload(
            summary: summary,
            topProject: topProject, topSessionId: topSessionId,
            timestamp: Int(now.timeIntervalSince1970)).utf8)
        _ = try? await URLSession.shared.data(for: request)
    }

    /// The `liveactivity` push body. `content-state` keys mirror
    /// `VibeBuddyActivityAttributes.ContentState`; optional strings are omitted when nil.
    nonisolated static func activityPayload(summary: TaskPresentationSummary,
                                            topProject: String?, topSessionId: String?,
                                            timestamp: Int) -> String {
        var state = #""summary":{"idle":\#(summary.idle),"thinking":\#(summary.thinking),"completeUnread":\#(summary.completeUnread),"requiresInput":\#(summary.requiresInput),"error":\#(summary.error)}"#
        if let p = topProject { state += #","topProject":"\#(escape(p))""# }
        if let s = topSessionId { state += #","topSessionId":"\#(escape(s))""# }
        return #"{"aps":{"timestamp":\#(timestamp),"event":"update","content-state":{\#(state)}}}"#
    }

    private func providerToken(now: Date) throws -> String {
        if let cached, now.timeIntervalSince(cached.issued) < 3000 { return cached.token }
        let token = try jwt.token(now: now)
        cached = (token, now)
        return token
    }

    nonisolated static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
         .replacingOccurrences(of: "\n", with: " ")
    }
}
