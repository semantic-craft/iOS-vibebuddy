import AppKit
import SwiftUI
import os
import VibeBuddyMacCore

/// Delivers the first mouse-down to the SwiftUI content even though the glance
/// panel isn't the key window — without this, taps on the non-activating panel
/// (jump / Approve / Deny) are swallowed.
private final class FirstMouseHostingView<V: View>: NSHostingView<V> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Keeps an always-active tracking area over the whole panel. SwiftUI's own
/// hover tracking only wakes up in an active app; this panel belongs to a
/// background accessory app that is never active, and without this area the
/// window server never tells the panel the pointer arrived, so `.onHover`
/// stays silent. With it, AppKit routes the enter/exit events on to SwiftUI.
private final class HoverTrackingView: NSView {
    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways],
                                       owner: self, userInfo: nil))
        super.updateTrackingAreas()
    }
}

/// A borderless panel can't become key by default, which blocks SwiftUI button
/// taps. Allow it — the panel is `.nonactivatingPanel`, so becoming key never
/// steals app focus or brings vibebuddy to the front.
private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    /// AppKit keeps key-capable windows below the menu bar; this one lives in it.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// The glance's window: one transparent panel, pre-sized to the largest thing
/// the glance ever draws and pinned to the top centre of the menu-bar screen.
/// It is never resized — the island grows and shrinks inside it in SwiftUI, and
/// the window server hit-tests the transparent surround away, so the menu bar
/// beside the notch stays clickable. (Re-measuring and re-framing the panel on
/// every state change is what used to trip AppKit's display cycle.)
@MainActor
final class GlanceWindow {
    private static let log = Logger(subsystem: "com.vibebuddy.app", category: "glance")
    /// Room for the widest card (400pt × the Large size) plus its flared corners.
    private static let panelSize = NSSize(width: 600, height: 440)
    private let panel: NSPanel
    private let hosting: NSHostingView<GlanceView>
    private let model: MenuBarModel
    private(set) var layout: GlanceLayout

    init(model: MenuBarModel) {
        self.model = model
        layout = Self.layout(for: Self.anchorScreen)
        hosting = FirstMouseHostingView(rootView: GlanceView(model: model, voice: model.voiceChat, layout: layout))
        hosting.frame = NSRect(origin: .zero, size: Self.panelSize)
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = NSColor.clear.cgColor
        hosting.layer?.isOpaque = false
        hosting.sizingOptions = []   // the window owns its frame; SwiftUI never resizes it
        hosting.safeAreaRegions = []  // the island sits in the menu-bar band; no inset for it
        panel = KeyablePanel(contentRect: NSRect(origin: .zero, size: Self.panelSize),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        // Above the menu bar (24) and its status items (25), like every notch app,
        // so the island covers the menu-bar band beside the housing and receives
        // the pointer there. Deliberately NOT `isFloatingPanel`: setting it
        // resets the level to `.floating` (3), which is what kept the old glance
        // *under* the menu bar and blind to the pointer. Clicks in the transparent
        // surround fall through regardless — the window server hit-tests by alpha.
        panel.level = .mainMenu + 3
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        let container = HoverTrackingView(frame: NSRect(origin: .zero, size: Self.panelSize))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.clear.cgColor
        container.layer?.isOpaque = false
        hosting.autoresizingMask = [.width, .height]
        container.addSubview(hosting)
        panel.contentView = container
        // Defer the first placement to the next runloop tick: placing while the
        // SwiftUI view graph is still being established has tripped AttributeGraph
        // preconditions before, and it keeps the panel hidden until positioned.
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
    }

    /// Position, raise above everything, and make visible. Safe to call repeatedly.
    func show() {
        reposition()
        panel.orderFrontRegardless()
        Self.log.notice("glance show layout=\(String(describing: self.layout), privacy: .public) frame=\(String(describing: self.panel.frame), privacy: .public)")
    }

    /// Remove the panel from screen (Settings → Show glance off). Reversible via `show()`.
    func hide() { panel.orderOut(nil) }

    /// Whether the island is on screen right now — what decides if a cue can be
    /// a card here or must be a banner.
    var isVisible: Bool { panel.isVisible }

    /// Anchor to the menu-bar screen, NOT `NSScreen.main`: on a multi-display Mac
    /// `NSScreen.main` follows keyboard focus and is non-deterministic at launch.
    /// `screens.first` is the display that owns the menu bar (and the notch).
    private static var anchorScreen: NSScreen? { NSScreen.screens.first ?? NSScreen.main }

    private func reposition() {
        guard let screen = Self.anchorScreen else { return }
        let next = Self.layout(for: screen)
        if next != layout {
            layout = next
            hosting.rootView = GlanceView(model: model, voice: model.voiceChat, layout: next)
        }
        let size = Self.panelSize
        let frame = NSRect(x: screen.frame.midX - size.width / 2, y: screen.frame.maxY - size.height,
                           width: size.width, height: size.height)
        panel.setFrame(frame, display: true)
    }

    /// The housing from `NSScreen`'s own metrics. `VIBEBUDDY_FAKE_NOTCH=185x32`
    /// pretends a notchless screen has one, so the notch layout can be exercised
    /// on an iMac; it is ignored on a real notch.
    private static func layout(for screen: NSScreen?) -> GlanceLayout {
        guard let screen else { return .pill(menuBarHeight: 24) }
        if let notch = NotchGeometry.from(screenWidth: screen.frame.width,
                                          topInset: screen.safeAreaInsets.top,
                                          auxiliaryLeftWidth: screen.auxiliaryTopLeftArea?.width,
                                          auxiliaryRightWidth: screen.auxiliaryTopRightArea?.width) {
            return .notch(notch)
        }
        if let fake = ProcessInfo.processInfo.environment["VIBEBUDDY_FAKE_NOTCH"] {
            let parts = fake.split(separator: "x").compactMap { Double($0) }
            if parts.count == 2 { return .notch(NotchGeometry(width: parts[0], height: parts[1])) }
        }
        return .pill(menuBarHeight: screen.frame.maxY - screen.visibleFrame.maxY)
    }
}
