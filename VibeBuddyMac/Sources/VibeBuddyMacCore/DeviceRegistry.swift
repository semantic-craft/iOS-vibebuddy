import Foundation
import VibeBuddyKit

public enum DeviceRegistryLocation {
    public static func defaultURL(
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        if let run = E2ERunConfiguration.current { return run.file("device-registry.json") }
        return home.appendingPathComponent("Library/Application Support/vibebuddy/device-registry.json")
    }
}

/// Apple's standing refusal of one phone's token — `BadDeviceToken` or
/// `Unregistered` — as a run: since when, how many sends in a row, and, once
/// the run has lasted long enough, when the Mac stopped pushing to it
/// (`parkedAt`). A run ends the moment Apple accepts a push for the token.
public struct DevicePushFailure: Codable, Sendable, Hashable {
    /// Apple's `reason` string, the one the run is counted under.
    public var reason: String
    public var status: Int
    public var firstAt: Date
    public var lastAt: Date
    public var count: Int
    /// Set when pushes to this token stopped. Cleared when the phone reports a
    /// push token again, which gives the token one more send to prove itself.
    public var parkedAt: Date?

    public init(reason: String, status: Int, firstAt: Date, lastAt: Date, count: Int,
                parkedAt: Date? = nil) {
        self.reason = reason
        self.status = status
        self.firstAt = firstAt
        self.lastAt = lastAt
        self.count = count
        self.parkedAt = parkedAt
    }

    public var isParked: Bool { parkedAt != nil }
}

/// When a run of `BadDeviceToken` on a once-accepted token stops the pushes.
/// Both bounds must hold: a handful of sends across a day, with nothing
/// accepted in between. A day, because one afternoon of the Mac being pointed
/// at the wrong APNs environment must not throw away every phone.
public struct DevicePushFailurePolicy: Sendable, Equatable {
    public var minimumFailures: Int
    public var minimumSpan: TimeInterval

    public init(minimumFailures: Int, minimumSpan: TimeInterval) {
        self.minimumFailures = max(1, minimumFailures)
        self.minimumSpan = max(0, minimumSpan)
    }

    public static let standard = DevicePushFailurePolicy(minimumFailures: 3, minimumSpan: 24 * 60 * 60)

    func parks(_ failure: DevicePushFailure) -> Bool {
        failure.count >= minimumFailures
            && failure.lastAt.timeIntervalSince(failure.firstAt) >= minimumSpan
    }
}

/// Where one phone's push stands, for a list that names every phone rather
/// than hiding the ones the Mac no longer pushes to.
public enum DevicePushStanding: Codable, Sendable, Hashable {
    /// Identified phone that has not reported an APNs token yet.
    case noToken
    /// Token on file with no standing refusal from Apple.
    case registered
    /// Apple has started refusing the token; pushes still go out.
    case failing(DevicePushFailure)
    /// Pushes to this token stopped. Revived when the phone reports a token again.
    case parked(DevicePushFailure)
}

/// One registered phone: the wire payload exactly as it arrived, plus when the
/// Mac last heard from it. The payload is nested rather than flattened so the
/// file stays decodable by anything that can decode `DeviceRegistrationPayload`.
public struct DeviceRegistryEntry: Codable, Sendable, Equatable {
    public var device: DeviceRegistrationPayload
    /// When this device last reported itself. Refreshed on every `POST /device`,
    /// so it answers "did the phone reconnect since the Mac restarted?".
    public var registeredAt: Date
    /// When Apple last accepted a push for this token, or nil if it never has.
    /// This is what separates a junk token from a misconfigured Mac when a 400
    /// comes back — see `APNsTokenOutcome`. Optional so entries written before
    /// the field existed still decode (and read as never-accepted, which is the
    /// safe answer: they get one chance to prove themselves).
    public var lastAcceptedAt: Date?
    /// Explicit Mac pairing consent; absent on historical registration-only records.
    public var pairedAt: Date?
    /// Apple's current run of refusals for the token, if any. Optional so
    /// entries written before the field existed decode as never refused.
    public var pushFailure: DevicePushFailure?

    public init(device: DeviceRegistrationPayload, registeredAt: Date,
                lastAcceptedAt: Date? = nil, pairedAt: Date? = nil,
                pushFailure: DevicePushFailure? = nil) {
        self.device = device
        self.registeredAt = registeredAt
        self.lastAcceptedAt = lastAcceptedAt
        self.pairedAt = pairedAt
        self.pushFailure = pushFailure
    }

    /// Pushes to this phone have been stood down; it is listed, not sent to.
    public var isParked: Bool { pushFailure?.isParked == true }

    /// Has a token the Mac will still send to.
    public var isPushable: Bool { device.hasPushToken && !isParked }

    public var pushStanding: DevicePushStanding {
        guard device.hasPushToken else { return .noToken }
        guard let failure = pushFailure else { return .registered }
        return failure.isParked ? .parked(failure) : .failing(failure)
    }
}

/// What Settings shows: how many phones the Mac can actually push to, and when
/// the newest of them last said so. Zero with APNs configured is the state that
/// used to be invisible — every push silently going nowhere.
public struct DeviceRegistrySummary: Sendable, Equatable {
    public var count: Int
    public var lastRegisteredAt: Date?
    /// Phones on file whose pushes have been stood down (`DevicePushStanding.parked`).
    public var parkedCount: Int

    public init(count: Int = 0, lastRegisteredAt: Date? = nil, parkedCount: Int = 0) {
        self.count = count
        self.lastRegisteredAt = lastRegisteredAt
        self.parkedCount = parkedCount
    }
}

/// Owner-only, atomically replaced registry of APNs device tokens, in the style
/// of `LifecycleJournal` / `NotificationDeliveryLog`. Persistence is best-effort:
/// unreadable, corrupt or future-schema data starts empty and every write
/// failure is contained here, so a broken file never stops session monitoring.
///
/// It exists because the registry used to be in-memory only: every Mac restart
/// emptied it, and no push reached a closed iPhone until the phone happened to
/// cold-launch and re-upload its token.
struct DeviceRegistry {
    /// Bounded because APNs tokens rotate (app reinstall, device restore) and a
    /// refused token is parked, not deleted, so it keeps its slot. A handful of
    /// phones is the real ceiling; the oldest registration loses, parked or not.
    static let maxEntries = 16

    /// What one send result did to the registry.
    enum Disposition: Equatable {
        /// Nothing about the token changed (a request fault, offline, 5xx).
        case unchanged
        /// Apple took it: the token is proven and any run of refusals is over.
        case accepted
        /// Apple refused it; the run is counted but pushes continue for now.
        case failing(DevicePushFailure)
        /// Pushes to this phone stopped, as of this result. The entry is what
        /// the caller logs.
        case parked(DeviceRegistryEntry)
    }

    private struct Envelope: Codable {
        let schemaVersion: Int
        let entries: [DeviceRegistryEntry]
        /// Tokens the user forgot. Optional so files written before the field
        /// existed still decode.
        var blocked: [String]? = nil
    }

    /// `nil` keeps the registry in memory — the default for tests and for the
    /// demo instance, which must never touch the user's real file.
    let url: URL?
    private let capacity: Int
    private let policy: DevicePushFailurePolicy
    private(set) var entries: [DeviceRegistryEntry]
    /// Tokens a "forget this phone" removed. A forgotten phone still holds the
    /// bearer token and re-reports itself on every reconnect, so without this
    /// the forget lasts only until the next network blip. Cleared when the user
    /// shows the pairing QR again.
    private(set) var blocked: Set<String>

    init(url: URL?, capacity: Int = DeviceRegistry.maxEntries,
         policy: DevicePushFailurePolicy = .standard) {
        self.url = url
        self.capacity = max(1, capacity)
        self.policy = policy
        guard let url,
              let data = try? Data(contentsOf: url),
              let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
              envelope.schemaVersion == 1 else {
            entries = []
            blocked = []
            return
        }
        entries = Self.pruned(envelope.entries.filter { $0.device.hasPushToken || $0.device.deviceID?.isEmpty == false },
                              capacity: self.capacity)
        blocked = Set(envelope.blocked ?? [])
    }

    /// The phones a push goes to: a token on file, and not parked.
    var devices: [DeviceRegistrationPayload] { entries.filter(\.isPushable).map(\.device) }

    var summary: DeviceRegistrySummary {
        DeviceRegistrySummary(count: devices.count,
                              lastRegisteredAt: entries.filter(\.isPushable).map(\.registeredAt).max(),
                              parkedCount: entries.filter(\.isParked).count)
    }

    /// Upsert a device, merging in only the preference fields this payload
    /// carries — a phone that reconnects before its APNs callback fires keeps
    /// the switches it uploaded last time.
    ///
    /// The phone's `deviceID` names it; a new token reported under the same
    /// id replaces its old record. Keying on the token alone left the old one
    /// standing, and Apple keeps delivering to a superseded token for a while,
    /// so a category the user had since switched off was still pushed through
    /// the stale record. A payload without an id (an older phone build, a raw
    /// token POST) is keyed on its token, and a record without an id is adopted
    /// by the first identified payload that carries the same token.
    @discardableResult
    mutating func upsert(_ payload: DeviceRegistrationPayload, now: Date, confirmingPairing: Bool = false) -> Bool {
        let token = payload.token.flatMap { $0.isEmpty ? nil : $0 }
        let id = payload.deviceID.flatMap { $0.isEmpty ? nil : $0 }
        guard token != nil || id != nil else { return false }
        guard token.map({ !blocked.contains($0) }) ?? true else { return false }
        let existing = id.flatMap { id in entries.first { $0.device.deviceID == id } }
            ?? entries.first { token != nil && $0.device.token == token }
        var merged = existing?.device ?? DeviceRegistrationPayload(token: token)
        if let token { merged.token = token }
        if let id { merged.deviceID = id }
        if let v = payload.name { merged.name = v }
        if let v = payload.model { merged.model = v }
        if let v = payload.systemVersion { merged.systemVersion = v }
        if let v = payload.playSound { merged.playSound = v }
        if let v = payload.quietMode { merged.quietMode = v }
        if let v = payload.categories { merged.categories = v }
        if let v = payload.supportsCompletionNotices { merged.supportsCompletionNotices = v }
        // An empty string is the phone saying it has no usable iCloud now.
        if let v = payload.cloudKitUser { merged.cloudKitUser = v.isEmpty ? nil : v }
        if let v = payload.cloudKitReceipts { merged.cloudKitReceipts = v }
        entries.removeAll { (token != nil && $0.device.token == token) || (id != nil && $0.device.deviceID == id) }
        // Re-registering does not re-prove the token: a phone that reconnects
        // keeps whatever standing it had with Apple. A *new* token starts from
        // nothing, whoever the phone is — Apple has not accepted it yet.
        let sameToken = existing?.device.token == merged.token
        let standing = sameToken ? existing?.lastAcceptedAt : nil
        // A phone that reports a push token is alive and talking to this Mac,
        // so a parked token gets its chance again. The run itself is kept:
        // if Apple still refuses, the very next send parks it again — one
        // `pruned` row per reconnect, not a day of `failed` rows. A new token
        // has no history. A report without a token changes nothing about push.
        let failure: DevicePushFailure? = {
            guard let existing = existing?.pushFailure else { return nil }
            guard token != nil else { return existing }
            guard sameToken else { return nil }
            var revived = existing
            revived.parkedAt = nil
            return revived
        }()
        entries.append(DeviceRegistryEntry(device: merged, registeredAt: now,
                                           lastAcceptedAt: standing,
                                           pairedAt: existing?.pairedAt ?? (confirmingPairing ? now : nil),
                                           pushFailure: failure))
        entries = Self.pruned(entries, capacity: capacity)
        persistBestEffort()
        return true
    }

    /// Apply one send result. Apple accepting the token ends any run of
    /// refusals and remembers the moment; `Unregistered` and a never-valid
    /// token park the phone at once; `BadDeviceToken` on a once-accepted token
    /// is counted, and parks the phone once the run satisfies `policy`.
    /// A parked phone keeps its record (identity, pairing, switches) so it is
    /// listed with the reason and revives when it reports a token again.
    /// `.parked` is returned only on the transition: a refusal that lands
    /// after the phone is already parked (a send that was in flight, or a
    /// different reason for the same dead token) changes nothing, so the
    /// ledger gets one `pruned` row per parking, not one per straggler.
    @discardableResult
    mutating func apply(_ result: APNsSendResult, token: String, now: Date) -> Disposition {
        guard let index = entries.firstIndex(where: { $0.device.token == token }) else { return .unchanged }
        let outcome = APNsDelivery.tokenOutcome(status: result.status, reason: result.reason,
                                                everAccepted: entries[index].lastAcceptedAt != nil)
        if outcome != .accepted, entries[index].isParked { return .unchanged }
        switch outcome {
        case .accepted:
            entries[index].lastAcceptedAt = now
            entries[index].pushFailure = nil
            persistBestEffort()
            return .accepted
        case .unregistered, .neverValid:
            var failure = Self.continued(entries[index].pushFailure, with: result, now: now)
            failure.parkedAt = now
            entries[index].pushFailure = failure
            persistBestEffort()
            return .parked(entries[index])
        case .suspect:
            var failure = Self.continued(entries[index].pushFailure, with: result, now: now)
            if policy.parks(failure) { failure.parkedAt = now }
            entries[index].pushFailure = failure
            persistBestEffort()
            return failure.isParked ? .parked(entries[index]) : .failing(failure)
        case .keep:
            return .unchanged
        }
    }

    /// The run this result extends: the same reason continues it, a different
    /// one starts over. Apple's word is what is counted; `status` is context.
    private static func continued(_ run: DevicePushFailure?, with result: APNsSendResult,
                                  now: Date) -> DevicePushFailure {
        let reason = result.reason ?? result.status.map { "apnsHTTP\($0)" } ?? "unknown"
        let status = result.status ?? 0
        if var run, run.reason == reason {
            run.count += 1
            run.lastAt = now
            run.status = status
            return run
        }
        return DevicePushFailure(reason: reason, status: status, firstAt: now, lastAt: now, count: 1)
    }

    /// Forget every device *and* refuse their tokens until `acceptNewRegistrations`.
    mutating func forgetAll() {
        blocked.formUnion(entries.compactMap(\.device.token))
        entries = []
        persistBestEffort()
    }

    mutating func acceptNewRegistrations() {
        guard !blocked.isEmpty else { return }
        blocked = []
        persistBestEffort()
    }

    /// Newest registration wins when the cap is hit.
    private static func pruned(
        _ entries: [DeviceRegistryEntry], capacity: Int
    ) -> [DeviceRegistryEntry] {
        guard entries.count > capacity else { return entries }
        return Array(entries.sorted { $0.registeredAt < $1.registeredAt }.suffix(capacity))
    }

    private func persistBestEffort() {
        guard let url else { return }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(Envelope(schemaVersion: 1, entries: entries,
                                                   blocked: blocked.isEmpty ? nil : blocked.sorted()))
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            // Fail open: the registry is a cache of what the phone told us, and
            // the phone re-reports on its next connection.
        }
    }
}
