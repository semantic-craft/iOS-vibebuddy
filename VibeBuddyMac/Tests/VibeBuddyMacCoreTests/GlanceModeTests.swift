#if canImport(CoreGraphics)
import Testing
import Foundation
@testable import VibeBuddyMacCore

@Suite("GlanceMode")
struct GlanceModeTests {
    @Test("a positive top safe-area inset (notch) → .notch")
    func notch() { #expect(GlanceMode.from(topInset: 32) == .notch) }

    @Test("zero top inset (no notch) → .pill")
    func pill() { #expect(GlanceMode.from(topInset: 0) == .pill) }
}
#endif
