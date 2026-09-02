import Foundation

/// The ambient "mood" of the whole dashboard, shown as the status buddy on both
/// platforms. Derived from the aggregate of all sessions, by urgency. Mirrors
/// the sound pack's granularity so the buddy's face matches the cue you hear.
public enum BuddyState: String, Sendable, Equatable, CaseIterable {
    case approval    // 🛡️ a permission/approval is waiting
    case question    // ❓ a question is waiting
    case longWait    // ⏰ a wait has dragged on
    case working     // ⚙️ actively running
    case stuck       // ⚠️ a run failed / got stuck
    case done        // ✅ at least one clean completion is unread
    case idle        // ○ sessions exist, with no unread completion
    case sleeping    // 😴 no sessions

    /// Pick the most urgent mood. Pass `now` to surface impatience after a long
    /// wait; without it, a long wait simply reads as approval/question.
    public static func from(_ groups: SessionGroups, now: Date? = nil,
                            longWaitThreshold: TimeInterval = 180) -> BuddyState {
        let sessions = groups.needsResponse + groups.working + groups.done
        if sessions.contains(where: { $0.presentationState == .error }) { return .stuck }
        let waiting = sessions.filter { $0.presentationState == .requiresInput }
        if !waiting.isEmpty {
            if let now, waiting.contains(where: { now.timeIntervalSince($0.statusSince) >= longWaitThreshold }) {
                return .longWait
            }
            return waiting.contains { $0.waitKind == .permission } ? .approval : .question
        }
        if sessions.contains(where: { $0.presentationState == .thinking }) { return .working }
        if sessions.contains(where: { $0.presentationState == .completeUnread }) { return .done }
        if !sessions.isEmpty { return .idle }
        return .sleeping
    }

    /// SF Symbol badge — shared so both platforms draw the same glyph.
    public var badgeSymbol: String {
        switch self {
        case .approval: return "lock.shield.fill"
        case .question: return "questionmark"
        case .longWait: return "clock.badge.exclamationmark.fill"
        case .working:  return "gearshape.fill"
        case .stuck:    return "exclamationmark.triangle.fill"
        case .done:     return "checkmark"
        case .idle:     return "circle"
        case .sleeping: return "moon.fill"
        }
    }

    /// Buddy eyes/emphasis use the same shared task state and color token as
    /// every other surface. Business moods still keep distinct face/symbol copy.
    public var presentationState: TaskPresentationState {
        switch self {
        case .approval, .question, .longWait: return .requiresInput
        case .working: return .thinking
        case .stuck: return .error
        case .done: return .completeUnread
        case .idle: return .idle
        case .sleeping: return .unassigned
        }
    }
}
