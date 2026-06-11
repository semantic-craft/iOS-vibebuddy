import AppKit

/// Reference-counted Dock visibility. The menu-bar app is `.accessory` (no Dock
/// icon); it becomes `.regular` while any real window is open and drops back to
/// `.accessory` when the last one closes.
@MainActor
enum AppActivationPolicy {
    private static var count = 0

    static func enter() {
        count += 1
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    static func leave() {
        count = max(0, count - 1)
        guard count == 0 else { return }
        NSApp.setActivationPolicy(.accessory)
    }

    /// Re-assert frontmost activation *after* a window has appeared. `enter()`
    /// activates before `openWindow`, so on recent macOS the window can end up
    /// key for the keyboard yet not the frontmost app — every mouse click is
    /// then swallowed as a click-to-activate. Calling this from the window's
    /// `onAppear` makes the app active so clicks land on the SwiftUI views.
    static func activateFront() {
        DispatchQueue.main.async {
            if let window = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeKey }) {
                moveOntoPresentationScreenIfNeeded(window)
                window.makeKeyAndOrderFront(nil)
            }
            NSApp.activate(ignoringOtherApps: true)
        }
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
