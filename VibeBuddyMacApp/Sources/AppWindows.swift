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
                size: NSSize(width: 1000, height: 660), minimum: NSSize(width: 760, height: 480),
                resizable: true)
        }
        present(dashboardWindow!)
    }

    func showSettings() {
        if settingsWindow == nil {
            settingsWindow = makeWindow(
                content: settingsContent, title: "Settings", id: "settings",
                size: NSSize(width: 500, height: 480), minimum: NSSize(width: 500, height: 480),
                resizable: false)
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
