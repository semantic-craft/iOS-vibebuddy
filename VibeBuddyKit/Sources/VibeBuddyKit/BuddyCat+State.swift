import SwiftUI

public extension BuddyCat.Mood {
    /// The in-app pet's mood for an aggregate `BuddyState`.
    init(_ state: BuddyState) {
        switch state {
        case .approval, .question: self = .alert
        case .longWait:            self = .wait
        case .working:             self = .working
        case .stuck:               self = .worry
        case .done:                self = .happy
        case .idle:                self = .calm
        case .sleeping:            self = .sleep
        }
    }

    /// The widget / Live Activity pet's mood for a presentation state.
    init(_ state: TaskPresentationState) {
        switch state {
        case .requiresInput:  self = .alert
        case .thinking:       self = .working
        case .error:          self = .worry
        case .completeUnread: self = .happy
        case .idle:           self = .calm
        case .unassigned:     self = .sleep
        }
    }
}

public extension BuddyCat {
    /// Only the attention states colour the eyes, straight from the shared
    /// status tokens. `idle`'s white token would vanish on the white cat and
    /// `completeUnread`'s green fails contrast on it, so resting and happy eyes
    /// are ink and a nap gets the lid grey.
    static func eyeColor(for mood: Mood) -> Color {
        switch mood {
        case .alert, .wait: return Color(taskStatus: .requiresInput)
        case .working:      return Color(taskStatus: .thinking)
        case .worry:        return Color(taskStatus: .error)
        case .calm, .happy: return ink
        case .sleep:        return lid
        }
    }
}
