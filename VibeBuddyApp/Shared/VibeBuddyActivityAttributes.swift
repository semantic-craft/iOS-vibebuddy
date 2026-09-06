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
        /// The approval the island can answer (island-approve/01): the leading
        /// session's pending request, its wording, and what it wants to touch.
        /// All nil when nothing is waiting, so older pushes decode unchanged.
        var approvalId: String?
        var approvalTitle: String?
        var approvalDetail: String?
        /// Set on the phone the moment a decision left it — `allow`, `deny`,
        /// or `failed` — so the banner answers before the Mac's next push does.
        var decisionSent: String?

        init(summary: TaskPresentationSummary, topProject: String? = nil, topSessionId: String? = nil,
             approvalId: String? = nil, approvalTitle: String? = nil, approvalDetail: String? = nil,
             decisionSent: String? = nil) {
            self.summary = summary
            self.topProject = topProject
            self.topSessionId = topSessionId
            self.approvalId = approvalId
            self.approvalTitle = approvalTitle
            self.approvalDetail = approvalDetail
            self.decisionSent = decisionSent
        }
    }
}
