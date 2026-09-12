import Foundation
import VibeBuddyKit

/// Build the shared tap-target deep link for the Widget and Live Activity.
/// (The static `ActivityCat` that lived here left with ADR-0017: the widget,
/// the island and the lock screen show a status glyph instead.)
func activitySessionURL(id: String) -> URL? {
    VibeBuddyDeepLink.sessionURL(id: id)
}
