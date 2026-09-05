import SwiftUI
import VibeBuddyKit

/// The Mac buddy: the same icon cat as iPhone and Watch, drawn by the Kit's
/// `BuddyCatFace` (ADR-0007, second amendment). This view owns the clock
/// (blink, mouth flap, a small bob while speaking) and the two Mac-only
/// decisions: `bare` for the black notch glance (no card, no shadow) and
/// `scale` for the glance's collapsed / expanded sizes. Under 34 pt wide the
/// cat drops its body and mouth so the head still reads at menu-bar height.
struct PetFace: View {
    let state: BuddyState
    var speaking: Bool = false
    var listening: Bool = false
    var bare: Bool = false
    var scale: CGFloat = 1

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var width: CGFloat { 50 * scale }
    private var showsBody: Bool { width >= BuddyCat.bodyThreshold }

    var body: some View {
        // ~10 fps is plenty for the blink/talk animation and easy on the battery
        // (the glance is always on screen).
        TimelineView(.periodic(from: .now, by: 0.1)) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            let blink = !reduceMotion && t.truncatingRemainder(dividingBy: 3.2) < 0.13
            let mouthOpen = speaking && Int(t / 0.16) % 2 == 0
            BuddyCatFace(mood: BuddyCat.Mood(state),
                         speaking: mouthOpen,
                         listening: listening,
                         blink: blink,
                         showsBody: showsBody,
                         showsMouth: width >= BuddyCat.mouthThreshold,
                         shadow: !bare && colorScheme == .light,
                         onDark: bare || colorScheme == .dark)
                .frame(width: width, height: BuddyCat.height(forWidth: width, showsBody: showsBody))
                .offset(y: speaking && !reduceMotion ? CGFloat(sin(t * 11)) * 0.8 * scale : 0)
        }
        .frame(width: 54 * scale, height: 60 * scale)
        .background {
            if !bare {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            }
        }
        .accessibilityHidden(true)
    }
}
