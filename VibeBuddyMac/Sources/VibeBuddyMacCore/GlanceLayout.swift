import CoreGraphics

/// The camera housing the glance anchors to, in points. Pure so the screen
/// arithmetic is testable without AppKit; `GlanceWindow` feeds it `NSScreen`.
public struct NotchGeometry: Equatable, Sendable {
    public var width: CGFloat
    public var height: CGFloat

    public init(width: CGFloat, height: CGFloat) {
        self.width = width
        self.height = height
    }

    /// Derive the housing from `NSScreen` metrics: the housing is whatever the
    /// two auxiliary top areas leave uncovered, as tall as the top safe-area
    /// inset. `nil` when the screen reports no auxiliary areas (no notch).
    public static func from(screenWidth: CGFloat, topInset: CGFloat,
                            auxiliaryLeftWidth: CGFloat?, auxiliaryRightWidth: CGFloat?) -> NotchGeometry? {
        guard let left = auxiliaryLeftWidth, let right = auxiliaryRightWidth, topInset > 0 else { return nil }
        let width = screenWidth - left - right
        guard width > 0 else { return nil }
        return NotchGeometry(width: width, height: topInset)
    }
}

/// How the glance renders: housing-width content below the camera, never
/// inside it, or a capsule hanging under the menu bar.
public enum GlanceLayout: Equatable, Sendable {
    case notch(NotchGeometry)
    case pill(menuBarHeight: CGFloat)

    public var notch: NotchGeometry? {
        if case .notch(let geometry) = self { return geometry }
        return nil
    }

    /// Input follows NSScreen.screens order (menu-bar screen first). Prefer an
    /// available hardware notch; otherwise stay on the menu-bar screen, never
    /// following keyboard focus. Empty input means no visible display.
    public static func preferredScreenIndex(in layouts: [GlanceLayout]) -> Int? {
        layouts.firstIndex { $0.notch != nil } ?? (layouts.isEmpty ? nil : 0)
    }
}
