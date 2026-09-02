import ActivityKit
import Foundation
import VibeBuddyKit

/// Live Activity content for the lock screen + Dynamic Island. The shared
/// presentation summary keeps the extension on the same status contract as apps.
struct VibeBuddyActivityAttributes: ActivityAttributes, Sendable {
    struct ContentState: Codable, Hashable, Sendable {
        var summary: TaskPresentationSummary
        var topProject: String?
        /// The session a tap should open (top needs-response, else working/done).
        var topSessionId: String?
    }
}
