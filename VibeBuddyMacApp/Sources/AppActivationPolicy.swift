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
}
