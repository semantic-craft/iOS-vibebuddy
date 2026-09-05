import SwiftUI
import VibeBuddyKit

/// The iOS buddy: the icon's white cat, drawn by the Kit's `BuddyCatFace` and
/// moved by `BuddyCatMotion` (ADR-0007, second amendment). This view only owns
/// the clock and the timestamps the motion needs: when the mood last changed,
/// when the companion stopped speaking, when the pet was greeted. It ticks at
/// 10 fps and lifts to 20 fps only while a reaction, greeting or voice phase
/// is running.
struct PetFace: View {
    let state: BuddyState
    var voice: BuddyCatMotion.Voice = .none
    /// Bump to make the cat wave (tap, panel opened).
    var greet: Int = 0

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var moodChangedAt = Date()
    @State private var speakingEndedAt: Date?
    @State private var greetedAt: Date?
    @State private var active = false

    private var input: BuddyCatMotion.Input {
        .init(mood: BuddyCat.Mood(state), moodChangedAt: moodChangedAt, voice: voice,
              speakingEndedAt: speakingEndedAt, greetedAt: greetedAt)
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: active ? 1 / 20 : 1 / 10,
                                paused: reduceMotion && voice != .speaking)) { tl in
            let f = BuddyCatMotion.frame(input, now: tl.date, reduceMotion: reduceMotion)
            BuddyCatFace(mood: f.mood, speaking: f.mouthOpen, listening: f.listening, blink: f.blink,
                         shadow: colorScheme == .light, onDark: colorScheme == .dark, pose: f.pose)
                .frame(width: 52, height: 60)
        }
        .onChange(of: state) { _, _ in moodChangedAt = Date(); wake() }
        .onChange(of: voice) { old, new in
            if old == .speaking, new == .none { speakingEndedAt = Date() }
            wake()
        }
        .onChange(of: greet) { _, _ in greetedAt = Date(); wake() }
        .onAppear { greetedAt = Date(); wake() }
    }

    /// Raise the frame rate for the reaction, then drop back once nothing moves.
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
