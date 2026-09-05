import Foundation

/// Which cues a device is allowed to turn into a notification at all.
///
/// One category per `NotificationSound`. `SoundPolicy` still decides *when* a
/// cue is earned; this decides whether the person wearing the device wants to
/// hear about that kind of thing. It is applied after the policy and before
/// anything is posted, so a disabled category never reaches the phone, and
/// therefore never reaches the Watch that mirrors it. Focus / Quiet mode stays a
/// separate override on top: it narrows an enabled set down to approvals.
///
/// Each device keeps its own value. The iPhone also uploads its copy with
/// `DeviceRegistrationPayload` so the Mac's remote push honours the phone's
/// switches when it delivers on the phone's behalf.
public struct NotificationCategoryPrefs: Codable, Sendable, Equatable {
    /// The `UserDefaults` key both apps store this under.
    public static let defaultsKey = "notificationCategories"

    /// The order the switches are shown in: the ones that block you first, then
    /// results, then the two that are off unless asked for.
    public static let displayOrder: [NotificationSound] = [
        .needsApproval, .needsAnswer, .agentStuck, .agentDone, .longWaitNudge, .pairSuccess,
    ]

    /// Approvals, questions, failures and completions on; the long-wait nudge
    /// and the pairing chime off.
    public static let `default` = NotificationCategoryPrefs(
        enabled: [.needsApproval, .needsAnswer, .agentStuck, .agentDone])

    public var enabled: Set<NotificationSound>

    public init(enabled: Set<NotificationSound>) {
        self.enabled = enabled
    }

    public func isEnabled(_ sound: NotificationSound) -> Bool {
        enabled.contains(sound)
    }

    public mutating func set(_ sound: NotificationSound, enabled on: Bool) {
        if on { enabled.insert(sound) } else { enabled.remove(sound) }
    }

    /// Drop the cues this device does not want to hear about.
    public func filter(_ alerts: [SoundAlert]) -> [SoundAlert] {
        alerts.filter { enabled.contains($0.sound) }
    }

    // MARK: Persistence

    /// The stored value, or the default when nothing has been saved or the
    /// saved value cannot be read.
    public static func load(from defaults: UserDefaults = .standard) -> NotificationCategoryPrefs {
        guard let data = defaults.data(forKey: defaultsKey),
              let prefs = try? JSONDecoder().decode(NotificationCategoryPrefs.self, from: data)
        else { return .default }
        return prefs
    }

    public func save(to defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }
}

public extension NotificationSound {
    /// The switch label for this cue's category, as shown in Settings on the
    /// iPhone and the Mac. Resolved through each app's own string table.
    var categoryTitle: LocalizedStringResource {
        switch self {
        case .needsApproval: return "Permission requests"
        case .needsAnswer:   return "Questions and waiting for input"
        case .agentStuck:    return "Errors and stuck sessions"
        case .agentDone:     return "Task completed"
        case .longWaitNudge: return "Still-waiting reminders"
        case .pairSuccess:   return "Pairing confirmation"
        }
    }
}
