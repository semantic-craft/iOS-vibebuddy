import AppKit
import SwiftUI

/// Owns ordinary windows for the lifetime of the app, independently of menu-bar views.
@MainActor
final class AppWindows: NSObject, NSWindowDelegate {
    private let dashboardContent: AnyView
    private let settingsContent: AnyView
    private(set) var dashboardWindow: NSWindow?
    private(set) var settingsWindow: NSWindow?

    init(dashboard: AnyView, settings: AnyView) {
        dashboardContent = dashboard
        settingsContent = settings
    }

    func showDashboard() {
        if dashboardWindow == nil {
            dashboardWindow = makeWindow(
                content: dashboardContent, title: "vibebuddy", id: "dashboard",
                size: NSSize(width: 1180, height: 760), minimum: NSSize(width: 940, height: 620),
                resizable: true)
        }
        present(dashboardWindow!)
    }

    func showSettings() {
        if settingsWindow == nil {
            settingsWindow = makeWindow(
                content: settingsContent, title: "Settings", id: "settings",
                // Ten pages that each fit without scrolling need the room.
                // Since the Connection & delivery section came back (ticket
                // 07) the tallest is General: 821pt of content at 1080 wide
                // with nothing to report, 50pt more per diagnostic row;
                // Notifications is 727pt. Narrowing past ~920 wraps the row
                // explanations into more lines than that, and a taller
                // minimum would not fit a 1440×900 13" display, so General
                // scrolls by ~60pt at the minimum and fits at the default.
                size: NSSize(width: 1080, height: 840), minimum: NSSize(width: 920, height: 760),
                resizable: true)
        }
        present(settingsWindow!)
    }

    private func makeWindow(content: AnyView, title: String, id: String,
                            size: NSSize, minimum: NSSize, resizable: Bool) -> NSWindow {
        var style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable]
        if resizable { style.insert(.resizable) }
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: style, backing: .buffered, defer: false)
        window.toolbarStyle = resizable ? .unified : .preference
        window.title = title
        window.identifier = NSUserInterfaceItemIdentifier("com.vibebuddy.\(id)")
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentViewController = NSHostingController(rootView: content)
        window.contentMinSize = minimum
        window.setContentSize(size)
        window.center()
        window.setFrameAutosaveName("VibeBuddy.\(id)")
        return window
    }

    private func present(_ window: NSWindow) {
        AppActivationPolicy.activate(window)
    }

    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow else { return }
        // Closing does not destroy the window. Repeated opens reuse its state;
        // Dock visibility depends on actual remaining windows, never click counts.
        let hasOrdinaryWindow = [dashboardWindow, settingsWindow].compactMap { $0 }
            .contains { $0 !== closing && ($0.isVisible || $0.isMiniaturized) }
        if !hasOrdinaryWindow { NSApp.setActivationPolicy(.accessory) }
    }
}
