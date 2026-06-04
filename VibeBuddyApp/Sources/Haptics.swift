import UIKit
import VibeBuddyKit

/// A light haptic to accompany an in-app cue. Maps each sound to a feedback
/// type that matches its weight — approvals/failures feel firmer, completion
/// softer. Respects the same mute toggle as sound.
enum Haptics {
    @MainActor
    static func play(for sound: NotificationSound) {
        guard SoundPrefs.playSound else { return }
        switch sound {
        case .needsApproval, .agentStuck:
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
        case .needsAnswer, .longWaitNudge:
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        case .agentDone, .pairSuccess:
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        }
    }
}
