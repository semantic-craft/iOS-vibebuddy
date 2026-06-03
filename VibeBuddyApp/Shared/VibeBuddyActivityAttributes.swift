import ActivityKit
import Foundation

/// Live Activity content for the lock screen + Dynamic Island. Self-contained
/// (no VibeBuddyKit dependency) so the widget extension stays lean.
struct VibeBuddyActivityAttributes: ActivityAttributes, Sendable {
    struct ContentState: Codable, Hashable, Sendable {
        var needsResponse: Int
        var working: Int
        var done: Int
        var topProject: String?
    }
}
