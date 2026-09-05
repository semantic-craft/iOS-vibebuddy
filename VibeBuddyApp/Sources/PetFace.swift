import SwiftUI
import VibeBuddyKit

/// The iOS buddy: the icon's white cat, drawn in code by the Kit's
/// `BuddyCatFace` (ADR-0007, second amendment). This view only owns the clock:
/// a blink every 3.2 s, the mouth flapping while the companion speaks, and the
/// listening ring. Reduce Motion stops the blink.
struct PetFace: View {
    let state: BuddyState
    var speaking: Bool = false
    var listening: Bool = false

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.1)) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            let blink = !reduceMotion && t.truncatingRemainder(dividingBy: 3.2) < 0.13
            let mouthOpen = speaking && Int(t / 0.16) % 2 == 0
            BuddyCatFace(mood: BuddyCat.Mood(state),
                         speaking: mouthOpen,
                         listening: listening,
                         blink: blink,
                         shadow: colorScheme == .light,
                         onDark: colorScheme == .dark)
                .frame(width: 52, height: 60)
        }
    }
}
