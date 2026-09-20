import CoreGraphics

/// The dashboard sidebar's width rules, kept pure so the snap arithmetic is
/// testable without SwiftUI. The sidebar has two settled shapes — labeled
/// (216 pt by default, free between `minLabeled` and `maxLabeled`) and an
/// icon-only rail — and a free width in between only while a drag is live.
public enum DashboardSidebarWidth {
    /// Glyph column only: outer 8 + row 8 + 14 glyph + 8 + outer 8, plus a
    /// little air so the selection wash reads as a tile.
    public static let iconOnly: CGFloat = 48
    /// Narrowest labeled width at rest; below it the labels would truncate
    /// every library name.
    public static let minLabeled: CGFloat = 168
    /// Cursor's sidebar width, the default and the width the labeled shape
    /// snaps back to.
    public static let labeledDefault: CGFloat = 216
    public static let maxLabeled: CGFloat = 320
    /// Release inside this distance of a settled width lands on it.
    public static let snapWindow: CGFloat = 28
    /// Released narrower than this and the sidebar settles icon-only; the
    /// midpoint between the two shapes, so release lands on the nearer one.
    public static var collapseThreshold: CGFloat { (iconOnly + minLabeled) / 2 }

    /// Labels are fully faded here and below…
    public static let labelFadeStart: CGFloat = 112
    /// …and fully shown here and above. The ramp runs while the free width
    /// crosses the collapse threshold, so nothing pops on either side of it.
    public static let labelFadeEnd: CGFloat = 160

    /// Where the pointer may take the width mid-drag: hard bounds, no
    /// rubber-banding, no snapping.
    public static func clampedDuringDrag(_ width: CGFloat) -> CGFloat {
        min(max(width, iconOnly), maxLabeled)
    }

    /// Whether a width draws the rail (glyphs only, titles in tooltips).
    public static func isIconOnly(at width: CGFloat) -> Bool {
        width < collapseThreshold
    }

    /// Opacity of titles, shortcuts and counts at a width: 0 on the rail,
    /// 1 at every labeled width, a linear ramp between.
    public static func labelOpacity(at width: CGFloat) -> CGFloat {
        guard width > labelFadeStart else { return 0 }
        guard width < labelFadeEnd else { return 1 }
        return (width - labelFadeStart) / (labelFadeEnd - labelFadeStart)
    }

    /// The width the sidebar settles on when a drag releases at `released`:
    /// the rail below the collapse threshold; otherwise the labeled range,
    /// snapped to the default when within `snapWindow` of it.
    public static func settled(released width: CGFloat) -> CGFloat {
        if isIconOnly(at: width) { return iconOnly }
        let labeled = min(max(width, minLabeled), maxLabeled)
        return abs(labeled - labeledDefault) <= snapWindow ? labeledDefault : labeled
    }
}
