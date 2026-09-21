import CoreGraphics
import Testing
@testable import VibeBuddyMacCore

@Suite("Dashboard column width")
struct DashboardColumnWidthTests {
    @Test(arguments: [DashboardColumnWidth.sidebar, DashboardColumnWidth.list])
    func releaseSnapsToTheNearerShapeAndKeepsFreeWidthsBetween(policy: DashboardColumnWidth) {
        let strip = policy.compact
        let narrowest = policy.minFull
        let standard = policy.fullDefault
        let widest = policy.maxFull
        let threshold = policy.collapseThreshold
        let snap = policy.snapWindow
        // Below the midpoint the strip wins; above it the full shape does,
        // never narrower than its minimum.
        #expect(policy.settled(released: strip) == strip)
        #expect(policy.settled(released: threshold - 1) == strip)
        #expect(policy.settled(released: threshold) == narrowest)
        // Near the default the full shape snaps to it; farther out the
        // free width is kept, up to the cap.
        #expect(policy.settled(released: standard - snap) == standard)
        let free: CGFloat = standard + snap + 1
        #expect(policy.settled(released: free) == free)
        #expect(policy.settled(released: 900) == widest)
        // A remembered width outside the range is healed on read.
        #expect(policy.clampedFull(0) == narrowest)
        #expect(policy.clampedFull(5000) == widest)
        // Mid-drag the pointer is followed inside hard bounds, never snapped.
        let nearStandard: CGFloat = standard - 3
        #expect(policy.clampedDuringDrag(nearStandard) == nearStandard)
        #expect(policy.clampedDuringDrag(10) == strip)
        // Words are gone before the strip layout takes over, and back before
        // the narrowest full width.
        #expect(policy.labelOpacity(at: threshold) == 0)
        #expect(policy.labelOpacity(at: narrowest) == 1)
        let midFade = (policy.labelFadeStart + policy.labelFadeEnd) / 2
        #expect(policy.labelOpacity(at: midFade) == 0.5)
        #expect(policy.isCompact(at: strip) && !policy.isCompact(at: narrowest))
    }

    @Test func aNarrowWindowLowersTheCapForDragReleaseAndRest() {
        let list = DashboardColumnWidth.list
        // The reader keeps its minimum: the list yields down to what is left,
        // even under its own minimum, but never under the strip.
        #expect(list.clampedDuringDrag(400, available: 260) == 260)
        #expect(list.settled(released: list.fullDefault, available: 260) == 260)
        #expect(list.clampedFull(list.maxFull, available: 200) == 200)
        #expect(list.clampedFull(list.maxFull, available: 10) == list.compact)
        // A comfortable window changes nothing.
        #expect(list.settled(released: list.fullDefault + 5, available: 1000) == list.fullDefault)
    }

    @Test func accessibilityStepsWalkTheFullRangeAndFoldAtTheBottom() {
        let list = DashboardColumnWidth.list
        let step = list.accessibilityStep
        let up = list.stepped(full: list.fullDefault, compact: false, direction: 1)
        #expect(up.full == list.fullDefault + step && !up.compact)
        let capped = list.stepped(full: list.maxFull, compact: false, direction: 1)
        #expect(capped.full == list.maxFull && !capped.compact)
        // Down from the narrowest full width folds to the strip and keeps the
        // full width for the way back.
        let folded = list.stepped(full: list.minFull, compact: false, direction: -1)
        #expect(folded.compact && folded.full == list.minFull)
        let unfolded = list.stepped(full: 333, compact: true, direction: 1)
        #expect(!unfolded.compact && unfolded.full == 333)
        let stillFolded = list.stepped(full: 333, compact: true, direction: -1)
        #expect(stillFolded.compact)
        // Under a window cap the step never stores a width the window cannot show.
        let windowed = list.stepped(full: 300, compact: false, direction: 1, available: 300)
        #expect(windowed.full == 300 && !windowed.compact)
        // Unfolding from the strip under a cap keeps the remembered width for
        // when the window is wide enough again.
        let remembered = list.stepped(full: 360, compact: true, direction: 1, available: 300)
        #expect(remembered.full == 360 && !remembered.compact)
    }
}
