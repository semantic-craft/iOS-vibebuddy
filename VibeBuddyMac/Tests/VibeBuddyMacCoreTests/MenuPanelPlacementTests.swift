import Foundation
import Testing
@testable import VibeBuddyMacCore

@Suite("Menu panel placement — centred under the icon, clamped to the screen")
struct MenuPanelPlacementTests {
    private let width: CGFloat = 360
    /// A 1512pt built-in display with the menu bar taken out of the top.
    private let builtIn = CGRect(x: 0, y: 0, width: 1512, height: 945)
    /// A second display sitting above and to the left of the first.
    private let secondary = CGRect(x: -1080, y: 945, width: 2560, height: 1415)

    private func x(_ itemMidX: CGFloat, on screen: CGRect) -> CGFloat {
        MenuPanelPlacement.x(itemMidX: itemMidX, panelWidth: width, visible: screen)
    }

    @Test func anIconInTheMiddleGetsAPanelCentredUnderIt() {
        #expect(x(756, on: builtIn) == 576)
        #expect(x(756, on: builtIn) + width / 2 == 756)
    }

    @Test func anIconAtTheFarRightClampsInsteadOfHangingOffTheScreen() {
        // Centring on an icon 20pt from the right edge would put the panel's
        // right edge at 1672 — 160pt past the display.
        let placed = x(1492, on: builtIn)
        #expect(placed == builtIn.maxX - width - MenuPanelPlacement.screenMargin)
        #expect(placed + width <= builtIn.maxX)
        #expect(builtIn.maxX - (placed + width) == MenuPanelPlacement.screenMargin)
    }

    @Test func anIconAtTheFarLeftClampsTheOtherWay() {
        let placed = x(30, on: builtIn)
        #expect(placed == builtIn.minX + MenuPanelPlacement.screenMargin)
        #expect(placed >= builtIn.minX)
    }

    @Test func aSecondDisplayIsClampedAgainstItsOwnBounds() {
        // Centred well inside it…
        #expect(x(0, on: secondary) == -180 as CGFloat)
        // …and clamped to *its* edges, not the main display's.
        #expect(x(secondary.maxX - 4, on: secondary)
                == secondary.maxX - width - MenuPanelPlacement.screenMargin)
        #expect(x(secondary.minX + 4, on: secondary)
                == secondary.minX + MenuPanelPlacement.screenMargin)
    }

    @Test func aPanelWiderThanTheScreenStillStartsInsideIt() {
        let narrow = CGRect(x: 0, y: 0, width: 200, height: 400)
        let placed = MenuPanelPlacement.x(itemMidX: 100, panelWidth: 360, visible: narrow)
        #expect(placed == narrow.minX + MenuPanelPlacement.screenMargin)
    }

    @Test func theSameIconGivesTheSameEdgeWhateverThePanelIsDoing() {
        // Height is not an input, so a panel that grows and shrinks — pinned
        // block appearing, search narrowing the list — cannot drift sideways.
        #expect(x(1100, on: builtIn) == x(1100, on: builtIn))
        // Only a width change moves it, and then by exactly half the change.
        let wide = MenuPanelPlacement.x(itemMidX: 1100, panelWidth: 400, visible: builtIn)
        #expect(x(1100, on: builtIn) - wide == 20)
    }
}
