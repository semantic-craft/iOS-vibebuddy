import SwiftUI
import VibeBuddyKit

/// The same icon cat the iPhone, Live Activity and Mac draw (ADR-0007, second
/// amendment), rendered static on the wrist: a companion that blinks on the
/// wrist is motion nobody asked for, and a still cat needs no Reduce Motion
/// special case. The Watch is always a black surface, so no shadow. Under
/// 34 pt only the head is drawn, which is what sits beside the headline.
struct WatchCat: View {
    let state: BuddyState
    var width: CGFloat = 44

    private var showsBody: Bool { width >= BuddyCat.bodyThreshold }

    var body: some View {
        BuddyCatFace(mood: BuddyCat.Mood(state),
                     showsBody: showsBody,
                     showsMouth: width >= BuddyCat.mouthThreshold,
                     onDark: true)
            .frame(width: width, height: BuddyCat.height(forWidth: width, showsBody: showsBody))
    }
}
