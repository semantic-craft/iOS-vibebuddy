// CoreGraphics (CGFloat) drives the macOS notch-glance geometry; excluded on Linux.
#if canImport(CoreGraphics)
import CoreGraphics

/// How the glance renders: hugging the hardware notch, or a floating pill.
/// Decided by the screen's top safe-area inset (notch Macs report > 0).
public enum GlanceMode: Sendable {
    case notch, pill
    public static func from(topInset: CGFloat) -> GlanceMode { topInset > 0 ? .notch : .pill }
}
#endif
