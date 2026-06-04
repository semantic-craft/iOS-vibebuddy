import Foundation

/// The ambient "mood" of the whole dashboard, shown as the iOS status buddy.
/// Derived from the aggregate of all sessions, by urgency priority.
public enum BuddyState: String, Sendable, Equatable {
    case needsResponse   // 🔔 something is waiting on you
    case working         // 🤖 actively running
    case done            // ✅ everything finished
    case sleeping        // 😴 no sessions

    /// Pick the most urgent state present: needsResponse → working → done → sleeping.
    public static func from(_ groups: SessionGroups) -> BuddyState {
        if !groups.needsResponse.isEmpty { return .needsResponse }
        if !groups.working.isEmpty { return .working }
        if !groups.done.isEmpty { return .done }
        return .sleeping
    }
}
