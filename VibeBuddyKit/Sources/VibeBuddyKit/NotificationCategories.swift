import Foundation

/// One switch in Settings. The six session cues share a name with
/// `NotificationSound`; `quota` is chrome (budget / usage) and has no sound file.
public enum NotificationCategory: String, Sendable, CaseIterable, Equatable, Codable {
    case needsApproval = "needs_approval"
    case needsAnswer = "needs_answer"
    case agentStuck = "agent_stuck"
    case agentDone = "agent_done"
    case longWaitNudge = "long_wait_nudge"
    case pairSuccess = "pair_success"
    case quota

    public init(_ sound: NotificationSound) {
        switch sound {
        case .needsApproval: self = .needsApproval
        case .needsAnswer:   self = .needsAnswer
        case .agentStuck:    self = .agentStuck
        case .agentDone:     self = .agentDone
        case .longWaitNudge: self = .longWaitNudge
        case .pairSuccess:   self = .pairSuccess
        }
    }

    /// The session cue this category gates, if it is one. `quota` is not.
    public var sound: NotificationSound? {
        switch self {
        case .needsApproval: return .needsApproval
        case .needsAnswer:   return .needsAnswer
        case .agentStuck:    return .agentStuck
        case .agentDone:     return .agentDone
        case .longWaitNudge: return .longWaitNudge
        case .pairSuccess:   return .pairSuccess
        case .quota:         return nil
        }
    }

    /// The switch label on iPhone and Mac Settings.
    public var categoryTitle: LocalizedStringResource {
        switch self {
        case .needsApproval: return "Permission requests"
        case .needsAnswer:   return "Questions and waiting for input"
        case .agentStuck:    return "Errors and stuck sessions"
        case .agentDone:     return "Task completed"
        case .longWaitNudge: return "Still-waiting reminders"
        case .pairSuccess:   return "Pairing confirmation"
        case .quota:         return "Usage and budget"
        }
    }
}

/// Which cues a device is allowed to turn into a notification at all.
///
/// Session cues map 1:1 from `NotificationSound`. `quota` is a seventh switch
/// that is not a session cue and is independent of the attention matrix.
/// `SoundPolicy` still decides *when* a session cue is earned; this decides
/// whether the person wearing the device wants to hear about that kind of
/// thing. It is applied after the policy and before anything is posted, so a
/// disabled category never reaches the phone, and therefore never reaches the
/// Watch that mirrors it.
///
/// Each device keeps its own value. The iPhone also uploads its copy with
/// `DeviceRegistrationPayload` so the Mac's remote push honours the phone's
/// switches when it delivers on the phone's behalf. Phone default: quota off.
/// Mac default: quota on. An old archive that lacks the `quota` key decodes as
/// that device's default.
public struct NotificationCategoryPrefs: Codable, Sendable, Equatable {
    /// The `UserDefaults` key both apps store this under.
    public static let defaultsKey = "notificationCategories"

    /// The order the switches are shown in: the ones that block you first, then
    /// results, then the two that are off unless asked for, then quota.
    public static let displayOrder: [NotificationCategory] = [
        .needsApproval, .needsAnswer, .agentStuck, .agentDone, .longWaitNudge, .pairSuccess, .quota,
    ]

    /// Approvals, questions, failures and completions on; the long-wait nudge,
    /// pairing chime and quota off. This is the phone / wire default.
    public static let `default` = NotificationCategoryPrefs(
        enabled: [.needsApproval, .needsAnswer, .agentStuck, .agentDone])

    /// Same as `default`, with quota on. Mac Settings and Mac local notices.
    public static let macDefault = NotificationCategoryPrefs(
        enabled: [.needsApproval, .needsAnswer, .agentStuck, .agentDone],
        quota: true)

    public var enabled: Set<NotificationSound>
    public var quota: Bool

    public init(enabled: Set<NotificationSound>, quota: Bool = false) {
        self.enabled = enabled
        self.quota = quota
    }

    public func isEnabled(_ sound: NotificationSound) -> Bool {
        enabled.contains(sound)
    }

    public func isEnabled(_ category: NotificationCategory) -> Bool {
        category.sound.map(isEnabled) ?? quota
    }

    public mutating func set(_ sound: NotificationSound, enabled on: Bool) {
        if on { enabled.insert(sound) } else { enabled.remove(sound) }
    }

    public mutating func set(_ category: NotificationCategory, enabled on: Bool) {
        if let sound = category.sound {
            set(sound, enabled: on)
        } else {
            quota = on
        }
    }

    /// Drop the session cues this device does not want to hear about.
    public func filter(_ alerts: [SoundAlert]) -> [SoundAlert] {
        alerts.filter { enabled.contains($0.sound) }
    }

    // MARK: Persistence

    /// Phone / wire load: a missing `quota` key is off.
    public static func load(from defaults: UserDefaults = .standard) -> NotificationCategoryPrefs {
        decodeStored(from: defaults, missingQuota: false, empty: .default)
    }

    /// Mac load: a missing `quota` key is on.
    public static func loadMac(from defaults: UserDefaults = .standard) -> NotificationCategoryPrefs {
        decodeStored(from: defaults, missingQuota: true, empty: .macDefault)
    }

    public func save(to defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }

    private static func decodeStored(from defaults: UserDefaults, missingQuota: Bool,
                                     empty: NotificationCategoryPrefs) -> NotificationCategoryPrefs {
        guard let data = defaults.data(forKey: defaultsKey) else { return empty }
        guard let prefs = try? decode(data, missingQuota: missingQuota) else { return empty }
        return prefs
    }

    static func decode(_ data: Data, missingQuota: Bool) throws -> NotificationCategoryPrefs {
        var prefs = try JSONDecoder().decode(NotificationCategoryPrefs.self, from: data)
        if !quotaKeyPresent(in: data) {
            prefs.quota = missingQuota
        }
        return prefs
    }

    private static func quotaKeyPresent(in data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        return object["quota"] != nil
    }

    enum CodingKeys: String, CodingKey { case enabled, quota }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = Set(try c.decode([NotificationSound].self, forKey: .enabled))
        quota = try c.decodeIfPresent(Bool.self, forKey: .quota) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(enabled.sorted { $0.rawValue < $1.rawValue }, forKey: .enabled)
        try c.encode(quota, forKey: .quota)
    }
}

public extension NotificationSound {
    /// The switch label for this cue's category. Prefer
    /// `NotificationCategory.categoryTitle` when iterating Settings.
    var categoryTitle: LocalizedStringResource {
        NotificationCategory(self).categoryTitle
    }
}
