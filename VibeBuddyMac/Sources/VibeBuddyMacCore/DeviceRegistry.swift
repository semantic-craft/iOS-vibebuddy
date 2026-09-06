import Foundation
import VibeBuddyKit

public enum DeviceRegistryLocation {
    public static func defaultURL(
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        home.appendingPathComponent("Library/Application Support/vibebuddy/device-registry.json")
    }
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

    public init(device: DeviceRegistrationPayload, registeredAt: Date,
                lastAcceptedAt: Date? = nil) {
        self.device = device
        self.registeredAt = registeredAt
        self.lastAcceptedAt = lastAcceptedAt
    }
}

/// What Settings shows: how many phones the Mac can actually push to, and when
/// the newest of them last said so. Zero with APNs configured is the state that
/// used to be invisible — every push silently going nowhere.
public struct DeviceRegistrySummary: Sendable, Equatable {
    public var count: Int
    public var lastRegisteredAt: Date?

    public init(count: Int = 0, lastRegisteredAt: Date? = nil) {
        self.count = count
        self.lastRegisteredAt = lastRegisteredAt
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
    /// rotated token is only evicted when Apple answers 410 for it. A handful of
    /// phones is the real ceiling; the oldest registration loses.
    static let maxEntries = 16

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
    private(set) var entries: [DeviceRegistryEntry]
    /// Tokens a "forget this phone" removed. A forgotten phone still holds the
    /// bearer token and re-reports itself on every reconnect, so without this
    /// the forget lasts only until the next network blip. Cleared when the user
    /// shows the pairing QR again.
    private(set) var blocked: Set<String>

    init(url: URL?, capacity: Int = DeviceRegistry.maxEntries) {
        self.url = url
        self.capacity = max(1, capacity)
        guard let url,
              let data = try? Data(contentsOf: url),
              let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
              envelope.schemaVersion == 1 else {
            entries = []
            blocked = []
            return
        }
        entries = Self.pruned(envelope.entries.filter { $0.device.hasPushToken },
                              capacity: self.capacity)
        blocked = Set(envelope.blocked ?? [])
    }

    var devices: [DeviceRegistrationPayload] { entries.map(\.device) }

    var summary: DeviceRegistrySummary {
        DeviceRegistrySummary(count: entries.count,
                              lastRegisteredAt: entries.map(\.registeredAt).max())
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
    mutating func upsert(_ payload: DeviceRegistrationPayload, now: Date) {
        guard let token = payload.token, !token.isEmpty, !blocked.contains(token) else { return }
        let id = payload.deviceID.flatMap { $0.isEmpty ? nil : $0 }
        let existing = id.flatMap { id in entries.first { $0.device.deviceID == id } }
            ?? entries.first { $0.device.token == token }
        var merged = existing?.device ?? DeviceRegistrationPayload(token: token)
        merged.token = token
        if let id { merged.deviceID = id }
        if let v = payload.name { merged.name = v }
        if let v = payload.model { merged.model = v }
        if let v = payload.systemVersion { merged.systemVersion = v }
        if let v = payload.playSound { merged.playSound = v }
        if let v = payload.quietMode { merged.quietMode = v }
        if let v = payload.categories { merged.categories = v }
        entries.removeAll { $0.device.token == token || (id != nil && $0.device.deviceID == id) }
        // Re-registering does not re-prove the token: a phone that reconnects
        // keeps whatever standing it had with Apple. A *new* token starts from
        // nothing, whoever the phone is — Apple has not accepted it yet.
        let standing = existing?.device.token == token ? existing?.lastAcceptedAt : nil
        entries.append(DeviceRegistryEntry(device: merged, registeredAt: now,
                                           lastAcceptedAt: standing))
        entries = Self.pruned(entries, capacity: capacity)
        persistBestEffort()
    }

    /// Apply one send result: drop a dead or never-valid token, and remember the
    /// moment Apple first took one. Returns true when the device was dropped.
    @discardableResult
    mutating func apply(_ result: APNsSendResult, token: String, now: Date) -> Bool {
        guard let index = entries.firstIndex(where: { $0.device.token == token }) else { return false }
        switch APNsDelivery.tokenOutcome(status: result.status, reason: result.reason,
                                         everAccepted: entries[index].lastAcceptedAt != nil) {
        case .accepted:
            entries[index].lastAcceptedAt = now
            persistBestEffort()
            return false
        case .unregistered, .neverValid:
            entries.remove(at: index)
            persistBestEffort()
            return true
        case .keep:
            return false
        }
    }

    @discardableResult
    mutating func remove(token: String) -> Bool {
        let before = entries.count
        entries.removeAll { $0.device.token == token }
        guard entries.count != before else { return false }
        persistBestEffort()
        return true
    }

    mutating func removeAll() {
        guard !entries.isEmpty else { return }
        entries = []
        persistBestEffort()
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
