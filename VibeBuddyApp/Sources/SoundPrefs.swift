import Foundation
import VibeBuddyKit

/// Single source of truth for the phone's sound preferences, read from
/// `UserDefaults` (the Settings sheet writes the same keys). Shared by the
/// notifier, the dashboard's `SoundPolicy`, and the Mac push registration.
enum SoundPrefs {
    static let playSoundKey = "playNotificationSound"
    static let quietModeKey = "quietMode"
    static let quietHoursKey = "quietHours"

    /// Sound on by default (absent key = true). Mute = off.
    static var playSound: Bool {
        UserDefaults.standard.object(forKey: playSoundKey) == nil
            ? true : UserDefaults.standard.bool(forKey: playSoundKey)
    }

    static var manualQuiet: Bool { UserDefaults.standard.bool(forKey: quietModeKey) }

    static var quietHours: QuietHours {
        guard let data = UserDefaults.standard.data(forKey: quietHoursKey),
              let q = try? JSONDecoder().decode(QuietHours.self, from: data)
        else { return QuietHours() }
        return q
    }

    static func setQuietHours(_ q: QuietHours) {
        if let data = try? JSONEncoder().encode(q) {
            UserDefaults.standard.set(data, forKey: quietHoursKey)
        }
    }

    /// Which cue categories this phone wants at all (and, by mirroring, the Watch).
    static var categories: NotificationCategoryPrefs {
        get { NotificationCategoryPrefs.load() }
        set { newValue.save() }
    }

    /// Quiet right now if the user toggled it on, or the nightly window is active.
    static func effectiveQuiet(now: Date = Date()) -> Bool {
        manualQuiet || quietHours.isQuiet(at: now)
    }
}
