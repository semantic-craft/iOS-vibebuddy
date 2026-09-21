import CoreGraphics

/// The width rules of a dashboard column that resizes from one edge, kept
/// pure so the snap arithmetic is testable without SwiftUI. Such a column
/// has two settled shapes — full (`fullDefault` by default, free between
/// `minFull` and `maxFull`) and compact (a glyph strip) — and a free width
/// in between only while a drag is live. The sidebar and the session list
/// are the two instances; they share every rule and differ only in numbers.
public struct DashboardColumnWidth: Sendable, Equatable {
    /// The compact strip: glyphs only, words in tooltips.
    public let compact: CGFloat
    /// Narrowest full width at rest; below it the words would truncate on
    /// every row.
    public let minFull: CGFloat
    /// The default, and the width the full shape snaps back to.
    public let fullDefault: CGFloat
    public let maxFull: CGFloat
    /// Release inside this distance of the default lands on it.
    public let snapWindow: CGFloat
    /// Words are fully faded here and below…
    public let labelFadeStart: CGFloat
    /// …and fully shown here and above. The ramp runs while the free width
    /// crosses the collapse threshold, so nothing pops on either side of it.
    public let labelFadeEnd: CGFloat
    /// How far one accessibility increment or decrement moves the full width.
    public let accessibilityStep: CGFloat

    public init(compact: CGFloat, minFull: CGFloat, fullDefault: CGFloat, maxFull: CGFloat,
                snapWindow: CGFloat = 28, labelFadeStart: CGFloat, labelFadeEnd: CGFloat,
                accessibilityStep: CGFloat = 16) {
        precondition(compact < minFull && minFull <= fullDefault && fullDefault <= maxFull)
        precondition(labelFadeStart < labelFadeEnd && labelFadeEnd <= minFull)
        // Words are gone by the time the strip layout takes over.
        precondition(labelFadeStart >= (compact + minFull) / 2)
        self.compact = compact
        self.minFull = minFull
        self.fullDefault = fullDefault
        self.maxFull = maxFull
        self.snapWindow = snapWindow
        self.labelFadeStart = labelFadeStart
        self.labelFadeEnd = labelFadeEnd
        self.accessibilityStep = accessibilityStep
    }

    /// The dashboard sidebar. Compact is the icon-only rail: outer 8 + row
    /// 8 + 14 glyph + 8 + outer 8, plus a little air so the selection wash
    /// reads as a tile. 216 is Cursor's sidebar width.
    public static let sidebar = DashboardColumnWidth(
        compact: 48, minFull: 168, fullDefault: 216, maxFull: 320,
        labelFadeStart: 112, labelFadeEnd: 160)

    /// The session list beside the reader (live and history share it).
    /// Compact keeps each row's 28 pt agent tile exactly where the full
    /// row draws it — 12 outer + 10 card padding on both sides — so the
    /// tiles never move while the words leave; 300 is the list's ideal
    /// width of old.
    public static let list = DashboardColumnWidth(
        compact: 72, minFull: 240, fullDefault: 300, maxFull: 380,
        labelFadeStart: 156, labelFadeEnd: 232)

    /// Released narrower than this and the column settles compact; the
    /// midpoint between the two shapes, so release lands on the nearer one.
    public var collapseThreshold: CGFloat { (compact + minFull) / 2 }

    /// The widest the column may be right now: its own cap, or less when
    /// the window cannot hold it beside its neighbour's minimum.
    private func cap(_ available: CGFloat?) -> CGFloat {
        guard let available else { return maxFull }
        return max(compact, min(maxFull, available))
    }

    /// Where the pointer may take the width mid-drag: hard bounds, no
    /// rubber-banding, no snapping.
    public func clampedDuringDrag(_ width: CGFloat, available: CGFloat? = nil) -> CGFloat {
        min(max(width, compact), cap(available))
    }

    /// A full width inside its resting range; also what a remembered width
    /// is passed through, so a stale or edited preference never lays the
    /// rows out narrower than the strip or wider than the cap. `available`
    /// lowers the cap when the window is too narrow for `maxFull`, and may
    /// take the column under `minFull` only in that case.
    public func clampedFull(_ width: CGFloat, available: CGFloat? = nil) -> CGFloat {
        min(max(width, minFull), cap(available))
    }

    /// Whether a width draws the compact strip (glyphs only, words in tooltips).
    public func isCompact(at width: CGFloat) -> Bool {
        width < collapseThreshold
    }

    /// Opacity of the words at a width: 0 on the strip, 1 at every full
    /// width, a linear ramp between.
    public func labelOpacity(at width: CGFloat) -> CGFloat {
        guard width > labelFadeStart else { return 0 }
        guard width < labelFadeEnd else { return 1 }
        return (width - labelFadeStart) / (labelFadeEnd - labelFadeStart)
    }

    /// The width the column settles on when a drag releases at `released`:
    /// the strip below the collapse threshold; otherwise the full range,
    /// snapped to the default when within `snapWindow` of it.
    public func settled(released width: CGFloat, available: CGFloat? = nil) -> CGFloat {
        if isCompact(at: width) { return compact }
        let full = clampedFull(width, available: available)
        return abs(full - fullDefault) <= snapWindow ? fullDefault : full
    }

    /// One accessibility increment (+1) or decrement (-1) from a settled
    /// shape: a step through the full range, folding to the strip below
    /// the narrowest full width and unfolding from it back to the
    /// remembered full width.
    public func stepped(full: CGFloat, compact isCompact: Bool, direction: Int,
                        available: CGFloat? = nil) -> (full: CGFloat, compact: Bool) {
        let current = clampedFull(full, available: available)
        if isCompact { return (current, direction <= 0) }
        if direction < 0, current <= minFull { return (current, true) }
        return (clampedFull(current + CGFloat(direction.signum()) * accessibilityStep, available: available), false)
    }
}
