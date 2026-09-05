import Testing
import Foundation
@testable import VibeBuddyKit

@Suite("BuddyCatMotion — reactions settle, expire, and yield to voice")
struct BuddyCatMotionTests {
    private let t0 = Date(timeIntervalSinceReferenceDate: 1_000)
    private func input(_ mood: BuddyCat.Mood, voice: BuddyCatMotion.Voice = .none,
                       speakingEndedAt: Date? = nil, greetedAt: Date? = nil) -> BuddyCatMotion.Input {
        .init(mood: mood, moodChangedAt: t0, voice: voice, speakingEndedAt: speakingEndedAt, greetedAt: greetedAt)
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

    @Test("a wait jumps twice then flicks an ear every 30 s")
    func waitingHopsThenReminds() {
        #expect(BuddyCatMotion.frame(input(.alert), now: t0 + 0.17).pose.bob < 0)
        #expect(BuddyCatMotion.frame(input(.alert), now: t0 + 2).pose.bob == 0)
        let reminder = BuddyCatMotion.frame(input(.alert), now: t0 + 0.7 + BuddyCatMotion.waitingReminderInterval + 0.1)
        #expect(reminder.pose.earR != 0)
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

    @Test("a greeting wave overrides the state motion, then the state resumes")
    func greetingOverrides() {
        let waving = BuddyCatMotion.frame(input(.happy, greetedAt: t0 + 3), now: t0 + 3.3)
        #expect(waving.pose.tilt < 0)
        let after = BuddyCatMotion.frame(input(.happy, greetedAt: t0 + 3), now: t0 + 3 + BuddyCatMotion.greetingDuration + 0.4)
        #expect(after.pose.tilt > 0)   // done's settled head tilt
    }

    @Test("voice phases sit on top: listening rings, speaking flaps, and the reply ends with a happy blink")
    func voiceLayers() {
        let listening = BuddyCatMotion.frame(input(.working, voice: .listening), now: t0 + 1)
        #expect(listening.listening)
        #expect(listening.mood == .working)
        let a = BuddyCatMotion.frame(input(.calm, voice: .speaking), now: t0 + 1.00)
        let b = BuddyCatMotion.frame(input(.calm, voice: .speaking), now: t0 + 1.16)
        #expect(a.mouthOpen != b.mouthOpen)
        let stillSpeaking = BuddyCatMotion.frame(input(.calm, voice: .speaking), now: t0 + 1, reduceMotion: true)
        #expect(stillSpeaking.pose.bob == 0)
        let ended = BuddyCatMotion.frame(input(.calm, speakingEndedAt: t0 + 2), now: t0 + 2.2)
        #expect(ended.mood == .happy)
    }

    @Test("small sprites keep only the jump")
    func reducedForWidth() {
        var p = BuddyCatPose()
        p.bob = -4; p.tilt = 3; p.earR = 8; p.dx = 1; p.breath = 1.01
        let small = p.reduced(forWidth: 20)
        #expect(small.bob == -4)
        #expect(small.tilt == 0 && small.earR == 0 && small.dx == 0 && small.breath == 1)
        #expect(p.reduced(forWidth: 32) == p)
    }

    @Test("isActive is true during reactions, greetings and voice, false at rest")
    func activity() {
        #expect(BuddyCatMotion.isActive(input(.calm), now: t0 + 1))
        #expect(!BuddyCatMotion.isActive(input(.calm), now: t0 + 60))
        #expect(BuddyCatMotion.isActive(input(.calm, voice: .thinking), now: t0 + 60))
        #expect(BuddyCatMotion.isActive(input(.calm, greetedAt: t0 + 60), now: t0 + 60.5))
    }
}
