import Foundation
import VibeBuddyKit

/// Labels retained for summaries saved before the global content preference.
public enum HistorySummaryStyle: String, Codable, Sendable {
    case briefing, review, record

    /// Short English labels; the app localizes them through its string tables.
    public var title: String {
        switch self {
        case .briefing: "Action briefing"
        case .review: "Session review"
        case .record: "Archive record"
        }
    }

}
