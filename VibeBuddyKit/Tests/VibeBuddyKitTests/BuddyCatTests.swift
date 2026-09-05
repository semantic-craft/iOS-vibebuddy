import Testing
import Foundation
@testable import VibeBuddyKit

@Suite("BuddyCat — mood mapping and sizing")
struct BuddyCatTests {

    @Test("every BuddyState maps to a mood; only attention states differ from calm")
    func buddyStateMoods() {
        #expect(BuddyCat.Mood(BuddyState.approval) == .alert)
        #expect(BuddyCat.Mood(BuddyState.question) == .alert)
        #expect(BuddyCat.Mood(BuddyState.longWait) == .wait)
        #expect(BuddyCat.Mood(BuddyState.working) == .working)
        #expect(BuddyCat.Mood(BuddyState.stuck) == .worry)
        #expect(BuddyCat.Mood(BuddyState.done) == .happy)
        #expect(BuddyCat.Mood(BuddyState.idle) == .calm)
        #expect(BuddyCat.Mood(BuddyState.sleeping) == .sleep)
    }

    @Test("a presentation state gives the same mood as the BuddyState it stands for")
    func presentationMoods() {
        for state in BuddyState.allCases where state != .longWait {
            #expect(BuddyCat.Mood(state.presentationState) == BuddyCat.Mood(state))
        }
        // The presentation vocabulary has no "waited too long"; it reads as alert.
        #expect(BuddyCat.Mood(BuddyState.longWait.presentationState) == .alert)
    }

    @Test("the unit canvas is 52×60 with the body and square for the head alone")
    func sizing() {
        #expect(BuddyCat.height(forWidth: 52, showsBody: true) == 60)
        #expect(BuddyCat.height(forWidth: 36, showsBody: false) == 36)
        #expect(BuddyCat.bodyThreshold > BuddyCat.mouthThreshold)
    }
}
