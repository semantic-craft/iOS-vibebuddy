import Testing
import Foundation
@testable import VibeBuddyKit

@Suite("BuddyCat — mood mapping and sizing")
struct BuddyCatTests {

    @Test("a presentation state gives the same mood as the BuddyState it stands for")
    func presentationMoods() {
        for state in BuddyState.allCases where state != .longWait {
            #expect(BuddyCat.Mood(state.presentationState) == BuddyCat.Mood(state))
        }
        // The presentation vocabulary has no "waited too long"; it reads as alert.
        #expect(BuddyCat.Mood(BuddyState.longWait.presentationState) == .alert)
    }
}
