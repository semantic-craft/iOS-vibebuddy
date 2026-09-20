import CoreGraphics
import Testing
@testable import VibeBuddyMacCore

@Suite("Dashboard sidebar width")
struct DashboardSidebarWidthTests {
    @Test func releaseSnapsToTheNearerShapeAndKeepsFreeWidthsBetween() {
        let rail = DashboardSidebarWidth.iconOnly
        let narrowest = DashboardSidebarWidth.minLabeled
        let standard = DashboardSidebarWidth.labeledDefault
        let widest = DashboardSidebarWidth.maxLabeled
        let threshold = DashboardSidebarWidth.collapseThreshold
        let snap = DashboardSidebarWidth.snapWindow
        // Below the midpoint the rail wins; above it the labeled shape does,
        // never narrower than its minimum.
        #expect(DashboardSidebarWidth.settled(released: rail) == rail)
        #expect(DashboardSidebarWidth.settled(released: threshold - 1) == rail)
        #expect(DashboardSidebarWidth.settled(released: threshold) == narrowest)
        // Near the default the labeled shape snaps to it; farther out the
        // free width is kept, up to the cap.
        #expect(DashboardSidebarWidth.settled(released: standard - snap) == standard)
        let free: CGFloat = standard + snap + 1
        #expect(DashboardSidebarWidth.settled(released: free) == free)
        #expect(DashboardSidebarWidth.settled(released: 900) == widest)
        // Mid-drag the pointer is followed inside hard bounds, never snapped.
        let nearStandard: CGFloat = standard - 3
        #expect(DashboardSidebarWidth.clampedDuringDrag(nearStandard) == nearStandard)
        #expect(DashboardSidebarWidth.clampedDuringDrag(10) == rail)
        // Labels are gone before the rail layout takes over, and back before
        // the narrowest labeled width.
        #expect(DashboardSidebarWidth.labelOpacity(at: threshold) == 0)
        #expect(DashboardSidebarWidth.labelOpacity(at: narrowest) == 1)
        let midFade = (DashboardSidebarWidth.labelFadeStart + DashboardSidebarWidth.labelFadeEnd) / 2
        #expect(DashboardSidebarWidth.labelOpacity(at: midFade) == 0.5)
        #expect(DashboardSidebarWidth.isIconOnly(at: rail) && !DashboardSidebarWidth.isIconOnly(at: narrowest))
    }
}
