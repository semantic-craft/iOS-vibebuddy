import SwiftUI
import VibeBuddyKit

/// The static icon cat for the Live Activity, Dynamic Island and home widget,
/// matching the in-app `PetFace` (ADR-0007, second amendment). These surfaces
/// are always dark, so no shadow; under 34 pt (the compact island) only the
/// head is drawn. The extension links VibeBuddyKit, so the mood and the eye
/// colour come from the same presentation state and tokens as everything else.
struct ActivityCat: View {
    let state: TaskPresentationState
    var size: CGFloat = 40
    /// The home widget sits on the Companion ground, not black.
    var onDark: Bool = true

    private var showsBody: Bool { size >= BuddyCat.bodyThreshold }

    var body: some View {
        BuddyCatFace(mood: BuddyCat.Mood(state),
                     showsBody: showsBody,
                     showsMouth: size >= BuddyCat.mouthThreshold,
                     shadow: !onDark,
                     onDark: onDark)
            .frame(width: size, height: BuddyCat.height(forWidth: size, showsBody: showsBody))
    }
}

/// Build the shared tap-target deep link for the Widget and Live Activity.
func activitySessionURL(id: String) -> URL? {
    VibeBuddyDeepLink.sessionURL(id: id)
}
