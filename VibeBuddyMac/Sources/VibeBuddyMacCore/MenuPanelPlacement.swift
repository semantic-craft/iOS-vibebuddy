import Foundation

/// Where the menu panel's left edge belongs on screen. `MenuBarExtra(.window)`
/// aligns either panel edge with the status item; this recentres it under
/// the icon, clamped to the hosting screen.
///
/// Pure arithmetic on purpose: the interesting cases are an icon so far right
/// that a centred panel would hang off the display, and a panel wider than the
/// display it is on. Neither can be produced by hand on a real menu bar.
public enum MenuPanelPlacement {
    /// Breathing room kept between the panel and the edge of the screen.
    public static let screenMargin: CGFloat = 8

    /// - Parameters:
    ///   - itemMidX: centre of the status item, in screen coordinates.
    ///   - panelWidth: the panel's own width.
    ///   - visible: the hosting screen's visible frame.
    /// - Returns: the panel's left edge — the icon's centre where it fits,
    ///   clamped to the screen with `screenMargin` at either edge otherwise.
    ///   The left margin wins when the panel is wider than the screen, so a
    ///   panel too wide to fit is never pushed off the left instead.
    public static func x(itemMidX: CGFloat, panelWidth: CGFloat, visible: CGRect) -> CGFloat {
        let leftmost = visible.minX + screenMargin
        let rightmost = max(leftmost, visible.maxX - panelWidth - screenMargin)
        return min(max(itemMidX - panelWidth / 2, leftmost), rightmost)
    }
}
