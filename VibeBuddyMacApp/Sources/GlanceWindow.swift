import AppKit
import SwiftUI
import Combine
import os
import VibeBuddyMacCore

/// Delivers the first mouse-down to the SwiftUI content even though the glance
/// panel isn't the key window — without this, taps on the non-activating panel
/// (jump / Approve / Deny) are swallowed.
private final class FirstMouseHostingView<V: View>: NSHostingView<V> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// A borderless panel can't become key by default, which blocks SwiftUI button
/// taps. Allow it — the panel is `.nonactivatingPanel`, so becoming key never
/// steals app focus or brings vibebuddy to the front.
private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class GlanceWindow {
    private static let log = Logger(subsystem: "com.vibebuddy.app", category: "glance")
    private let panel: NSPanel
    private let container: NSView
    private let hosting: NSHostingView<GlanceView>
    private let measuringController: NSHostingController<GlanceView>
    private let mode: GlanceMode
    private var lastContentSize = NSSize(width: 140, height: 28)
    private var cancellables: Set<AnyCancellable> = []

    init(model: MenuBarModel) {
        // Use the menu-bar screen (screens.first), the same anchor reposition()
        // uses, so notch-vs-pill detection matches where the panel is placed.
        let anchor = NSScreen.screens.first ?? NSScreen.main
        mode = GlanceMode.from(topInset: anchor?.safeAreaInsets.top ?? 0)
        let rootView = GlanceView(model: model, voice: model.voiceChat, mode: mode)
        hosting = FirstMouseHostingView(rootView: rootView)
        measuringController = NSHostingController(rootView: rootView)
        let initialSize = NSSize(width: 220, height: mode == .notch ? 38 : 30)
        container = NSView(frame: NSRect(origin: .zero, size: initialSize))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.clear.cgColor
        container.layer?.isOpaque = false
        hosting.frame = container.bounds
        hosting.autoresizingMask = [.width, .height]
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = NSColor.clear.cgColor
        hosting.layer?.isOpaque = false
        if #available(macOS 13.0, *) {
            // The glance window owns its frame. Leaving NSHostingView's default
            // window-sizing bridge enabled can create a display-cycle loop:
            // SwiftUI updates intrinsic size, AppKit resizes the NSPanel, safe
            // area changes invalidate SwiftUI again, and AppKit eventually traps.
            hosting.sizingOptions = []
        }
        panel = KeyablePanel(contentRect: NSRect(origin: .zero, size: initialSize),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        container.addSubview(hosting)
        panel.contentView = container
        // Defer the first sizing+placement to the next runloop tick. Synchronously
        // measuring and placing while the SwiftUI view graph is still being
        // established has tripped AttributeGraph preconditions before. Deferring
        // also keeps the panel hidden until positioned (no bottom-left flash).
        DispatchQueue.main.async { [weak self] in self?.show() }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.reposition() }
        }
        // App may not have finished launching when init runs; re-assert front then.
        NotificationCenter.default.addObserver(forName: NSApplication.didFinishLaunchingNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.show() }
        }
        model.$glanceScale.dropFirst()
            .sink { [weak self] _ in self?.scheduleReposition() }
            .store(in: &cancellables)
        model.$glanceExpanded.dropFirst()
            .sink { [weak self] _ in self?.scheduleReposition() }
            .store(in: &cancellables)
        model.$sessions.dropFirst()
            .sink { [weak self] _ in self?.scheduleReposition() }
            .store(in: &cancellables)
    }

    /// Position, raise above everything, and make visible. Safe to call repeatedly.
    func show() {
        reposition()
        panel.orderFrontRegardless()
        Self.log.notice("glance show mode=\(String(describing: self.mode), privacy: .public) frame=\(String(describing: self.panel.frame), privacy: .public) contentSize=\(String(describing: self.lastContentSize), privacy: .public) isVisible=\(self.panel.isVisible) occluded=\(self.panel.occlusionState.contains(.visible))")
    }

    /// Remove the panel from screen (Settings → Show glance off). Reversible via `show()`.
    func hide() { panel.orderOut(nil) }

    func reposition() {
        // Anchor to the menu-bar screen, NOT `NSScreen.main`. On a multi-display
        // Mac, `NSScreen.main` is the screen with keyboard focus and is
        // non-deterministic at launch, so the panel would land top-center of
        // whichever display happened to have focus — often the wrong monitor,
        // which is why the glance "sometimes didn't appear". `screens.first` is
        // the display that owns the menu bar (coordinate-system origin).
        guard let screen = NSScreen.screens.first ?? NSScreen.main else { return }
        let size = measuredContentSize(on: screen)
        lastContentSize = size
        let w = max(size.width, 140), h = max(size.height, 28)
        let x = screen.frame.midX - w / 2
        let y = screen.frame.maxY - h
        let frame = NSRect(x: x, y: y, width: w, height: h)
        panel.setFrame(frame, display: true)
        container.frame = NSRect(origin: .zero, size: frame.size)
        hosting.frame = container.bounds
        container.needsDisplay = true
        hosting.needsDisplay = true
        panel.displayIfNeeded()
    }

    private func measuredContentSize(on screen: NSScreen) -> NSSize {
        let maxWidth = min(screen.frame.width - 80, 560)
        // Propose the usable height rather than a guessed cap: expanded the glance
        // is a header plus up to six session rows, which no longer fits in 280pt.
        // SwiftUI still reports the *ideal* height, so the collapsed pill stays short.
        let maxHeight = max(160, screen.visibleFrame.height - 40)
        let measured = measuringController.sizeThatFits(in: NSSize(width: maxWidth, height: maxHeight))
        guard measured.width.isFinite, measured.height.isFinite,
              measured.width > 0, measured.height > 0 else {
            return NSSize(width: 140, height: mode == .notch ? 38 : 28)
        }
        return NSSize(width: min(measured.width, maxWidth), height: min(measured.height, maxHeight))
    }

    private func scheduleReposition() {
        DispatchQueue.main.async { [weak self] in self?.reposition() }
    }
}
