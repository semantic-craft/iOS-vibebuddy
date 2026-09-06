import AppKit

/// Activate only the requested ordinary window. Floating panels are never candidates.
@MainActor
enum AppActivationPolicy {
    static func activate(_ window: NSWindow) {
        NSApp.setActivationPolicy(.regular)
        if window.isMiniaturized { window.deminiaturize(nil) }
        if !window.styleMask.contains(.fullScreen) {
            moveOntoPresentationScreenIfNeeded(window)
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private static func moveOntoPresentationScreenIfNeeded(_ window: NSWindow) {
        guard let screen = presentationScreen() else { return }
        let visible = screen.visibleFrame.insetBy(dx: 18, dy: 18)
        guard !visible.contains(window.frame) else { return }
        var frame = window.frame
        let x = centeredOrigin(for: frame.width, within: visible.minX...visible.maxX)
        let y = centeredOrigin(for: frame.height, within: visible.minY...visible.maxY)
        frame.origin = NSPoint(x: x, y: y)
        window.setFrame(frame, display: true)
    }

    private static func presentationScreen() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
    }

    private static func centeredOrigin(for length: CGFloat, within range: ClosedRange<CGFloat>) -> CGFloat {
        let maxOrigin = max(range.lowerBound, range.upperBound - length)
        let centered = range.lowerBound + (range.upperBound - range.lowerBound - length) / 2
        return min(max(centered, range.lowerBound), maxOrigin)
    }
}
