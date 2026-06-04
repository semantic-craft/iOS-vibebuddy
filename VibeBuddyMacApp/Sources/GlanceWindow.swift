import AppKit
import SwiftUI
import Combine
import os
import VibeBuddyMacCore

@MainActor
final class GlanceWindow {
    private static let log = Logger(subsystem: "com.vibebuddy.app", category: "glance")
    private let panel: NSPanel
    private let hosting: NSHostingView<GlanceView>
    private let mode: GlanceMode
    private var cancellable: AnyCancellable?

    init(model: MenuBarModel) {
        // Use the menu-bar screen (screens.first), the same anchor reposition()
        // uses, so notch-vs-pill detection matches where the panel is placed.
        let anchor = NSScreen.screens.first ?? NSScreen.main
        mode = GlanceMode.from(topInset: anchor?.safeAreaInsets.top ?? 0)
        hosting = NSHostingView(rootView: GlanceView(model: model, mode: mode))
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 220, height: mode == .notch ? 38 : 30),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.contentView = hosting
        show()
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.reposition() }
        }
        // App may not have finished launching when init runs; re-assert front then.
        NotificationCenter.default.addObserver(forName: NSApplication.didFinishLaunchingNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.show() }
        }
        cancellable = model.$glanceScale.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.reposition() }
        }
    }

    /// Position, raise above everything, and make visible. Safe to call repeatedly.
    func show() {
        reposition()
        panel.orderFrontRegardless()
        Self.log.notice("glance show mode=\(String(describing: self.mode), privacy: .public) frame=\(String(describing: self.panel.frame), privacy: .public) fitting=\(String(describing: self.hosting.fittingSize), privacy: .public) isVisible=\(self.panel.isVisible) occluded=\(self.panel.occlusionState.contains(.visible))")
    }

    func reposition() {
        // Anchor to the menu-bar screen, NOT `NSScreen.main`. On a multi-display
        // Mac, `NSScreen.main` is the screen with keyboard focus and is
        // non-deterministic at launch, so the panel would land top-center of
        // whichever display happened to have focus — often the wrong monitor,
        // which is why the glance "sometimes didn't appear". `screens.first` is
        // the display that owns the menu bar (coordinate-system origin).
        guard let screen = NSScreen.screens.first ?? NSScreen.main else { return }
        let size = hosting.fittingSize
        let w = max(size.width, 140), h = max(size.height, 28)
        let x = screen.frame.midX - w / 2
        let y = screen.frame.maxY - h
        panel.setFrame(NSRect(x: x, y: y, width: w, height: h), display: true)
    }
}
