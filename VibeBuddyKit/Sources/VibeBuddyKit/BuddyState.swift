import Foundation

/// A semantic accent role, mapped to a concrete color by each platform's view
/// so the buddy reads the same on iOS and Mac.
public enum BuddyAccent: String, Sendable, Equatable {
    case alert       // a security approval is waiting
    case curious     // a question is waiting
    case impatient   // a wait has dragged on
    case busy        // actively running
    case worry       // a run failed / got stuck
    case good        // everything finished cleanly
    case calm        // idle
}

/// The ambient "mood" of the whole dashboard, shown as the status buddy on both
/// platforms. Derived from the aggregate of all sessions, by urgency. Mirrors
/// the sound pack's granularity so the buddy's face matches the cue you hear.
public enum BuddyState: String, Sendable, Equatable, CaseIterable {
    case approval    // 🛡️ a permission/approval is waiting
    case question    // ❓ a question is waiting
    case longWait    // ⏰ a wait has dragged on
    case working     // ⚙️ actively running
    case stuck       // ⚠️ a run failed / got stuck
    case done        // ✅ everything finished
    case sleeping    // 😴 no sessions

    /// Pick the most urgent mood. Pass `now` to surface impatience after a long
    /// wait; without it, a long wait simply reads as approval/question.
    public static func from(_ groups: SessionGroups, now: Date? = nil,
                            longWaitThreshold: TimeInterval = 180) -> BuddyState {
        let waiting = groups.needsResponse
        if !waiting.isEmpty {
            if let now, waiting.contains(where: { now.timeIntervalSince($0.statusSince) >= longWaitThreshold }) {
                return .longWait
            }
            return waiting.contains { $0.waitKind == .permission } ? .approval : .question
        }
        if !groups.working.isEmpty { return .working }
        if groups.done.contains(where: { $0.isStuck }) { return .stuck }
        if !groups.done.isEmpty { return .done }
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
        case .sleeping: return "moon.fill"
        }
    }

    public var accent: BuddyAccent {
        switch self {
        case .approval: return .alert
        case .question: return .curious
        case .longWait: return .impatient
        case .working:  return .busy
        case .stuck:    return .worry
        case .done:     return .good
        case .sleeping: return .calm
        }
    }
}
