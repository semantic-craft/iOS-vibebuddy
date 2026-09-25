import Testing
import Foundation
@testable import VibeBuddyKit

@Suite("BuddyCatMotion — reactions settle, expire, and yield to voice")
struct BuddyCatMotionTests {
    private let t0 = Date(timeIntervalSinceReferenceDate: 1_000)
    private func input(_ mood: BuddyCat.Mood, voice: BuddyCatMotion.Voice = .none,
                       greetedAt: Date? = nil) -> BuddyCatMotion.Input {
        .init(mood: mood, moodChangedAt: t0, voice: voice, speakingEndedAt: nil, greetedAt: greetedAt)
    }

    @Test("working sways for the reaction, then only the eyes scan, then even that expires")
    func workingReactionExpires() {
        let burst = BuddyCatMotion.frame(input(.working), now: t0 + 0.2)
        #expect(burst.pose.dx != 0 || burst.pose.earL != 0)
        let settled = BuddyCatMotion.frame(input(.working), now: t0 + 5.3)
        #expect(settled.pose.dx == 0)
        #expect(settled.pose.eyeDx != 0)
        let expired = BuddyCatMotion.frame(input(.working), now: t0 + BuddyCatMotion.workingLifetime + 5.3)
        #expect(expired.pose.eyeDx == 0)
        #expect(expired.pose.dx == 0)
    }

    @Test("stuck keeps its sweat drop after the shake, and Reduce Motion keeps only that")
    func stuckSweat() {
        let later = BuddyCatMotion.frame(input(.worry), now: t0 + 4)
        #expect(later.pose.dx == 0)
        #expect(later.pose.sweat == 1)
        let still = BuddyCatMotion.frame(input(.worry), now: t0 + 0.3, reduceMotion: true)
        #expect(still.pose.dx == 0)
        #expect(still.pose.breath == 1)
        #expect(still.pose.sweat > 0)
        #expect(still.blink == false)
    }

    @Test("isActive is true during reactions, greetings and voice, false at rest")
    func activity() {
        #expect(BuddyCatMotion.isActive(input(.calm), now: t0 + 1))
        #expect(!BuddyCatMotion.isActive(input(.calm), now: t0 + 60))
        #expect(BuddyCatMotion.isActive(input(.calm, voice: .thinking), now: t0 + 60))
        #expect(BuddyCatMotion.isActive(input(.calm, greetedAt: t0 + 60), now: t0 + 60.5))
    }
}
