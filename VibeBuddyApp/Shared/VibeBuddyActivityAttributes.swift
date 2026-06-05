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
        /// The session a tap should open (top needs-response, else working/done).
        /// Optional so older payloads decode; the activity just opens the app then.
        var topSessionId: String?
    }
}
