import SwiftUI
import Testing
@testable import VibeBuddyKit

@Suite("Companion type — sizes scale with the system ramp")
struct CompanionTypeTests {
    private static let ramp: [Font.TextStyle] = [
        .caption2, .caption, .footnote, .subheadline, .body, .headline,
        .title3, .title2, .title, .largeTitle,
    ]

    @Test("the size → text style map never steps down as the size grows")
    func styleMapIsMonotonic() {
        var last = -1
        for size in stride(from: CGFloat(6), through: 40, by: 0.5) {
            let index = Self.ramp.firstIndex(of: CompanionType.textStyle(for: size))!
            #expect(index >= last, "size \(size) scales with a smaller ramp than the size before it")
            last = index
        }
    }

    @Test("the ramp's anchors land where the tokens are used")
    func anchors() {
        #expect(CompanionType.textStyle(for: 9.5) == .caption2)
        #expect(CompanionType.textStyle(for: 11.5) == .footnote)
        #expect(CompanionType.textStyle(for: 13) == .subheadline)
        #expect(CompanionType.textStyle(for: 15) == .body)
        #expect(CompanionType.textStyle(for: 28) == .largeTitle)
    }
}
