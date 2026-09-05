import SwiftUI
import VibeBuddyKit

/// The Mac buddy: the same icon cat as iPhone and Watch, drawn by the Kit's
/// `BuddyCatFace` and moved by `BuddyCatMotion` (ADR-0007, second amendment).
/// This view owns the clock and the two Mac-only decisions: `bare` for the
/// black notch glance (no card, no shadow) and `scale` for the glance's
/// collapsed / expanded sizes. Under 34 pt wide the cat drops its body and
/// mouth, and under 28 pt only the jump survives of the motion, so the head
/// still reads at menu-bar height instead of shimmering.
struct PetFace: View {
    let state: BuddyState
    var voice: BuddyCatMotion.Voice = .none
    /// Bump to make the cat wave (tap, panel opened).
    var greet: Int = 0
    var bare: Bool = false
    var scale: CGFloat = 1

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var moodChangedAt = Date()
    @State private var speakingEndedAt: Date?
    @State private var greetedAt: Date?
    @State private var active = false

    private var width: CGFloat { 50 * scale }
    private var showsBody: Bool { width >= BuddyCat.bodyThreshold }

    private var input: BuddyCatMotion.Input {
        .init(mood: BuddyCat.Mood(state), moodChangedAt: moodChangedAt, voice: voice,
              speakingEndedAt: speakingEndedAt, greetedAt: greetedAt)
    }

    var body: some View {
        // 10 fps at rest is easy on the battery (the glance is always on screen);
        // 20 fps only while something is actually moving.
        TimelineView(.animation(minimumInterval: active ? 1 / 20 : 1 / 10,
                                paused: reduceMotion && voice != .speaking)) { tl in
            let f = BuddyCatMotion.frame(input, now: tl.date, reduceMotion: reduceMotion)
            BuddyCatFace(mood: f.mood, speaking: f.mouthOpen, listening: f.listening, blink: f.blink,
                         showsBody: showsBody,
                         showsMouth: width >= BuddyCat.mouthThreshold,
                         shadow: !bare && colorScheme == .light,
                         onDark: bare || colorScheme == .dark,
                         pose: f.pose.reduced(forWidth: width))
                .frame(width: width, height: BuddyCat.height(forWidth: width, showsBody: showsBody))
        }
        .frame(width: 54 * scale, height: 60 * scale)
        .background {
            if !bare {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            }
        }
        .accessibilityHidden(true)
        .onChange(of: state) { _, _ in moodChangedAt = Date(); wake() }
        .onChange(of: voice) { old, new in
            if old == .speaking, new == .none { speakingEndedAt = Date() }
            wake()
        }
        .onChange(of: greet) { _, _ in greetedAt = Date(); wake() }
        .onAppear { greetedAt = Date(); wake() }
    }

    private func wake() {
        active = true
        Task {
            try? await Task.sleep(for: .seconds(3.5))
            active = BuddyCatMotion.isActive(input, now: Date())
        }
    }
}

extension BuddyCatMotion.Voice {
    init(_ phase: VoiceChat.Phase) {
        switch phase {
        case .idle:      self = .none
        case .listening: self = .listening
        case .thinking:  self = .thinking
        case .speaking:  self = .speaking
        }
    }
}
