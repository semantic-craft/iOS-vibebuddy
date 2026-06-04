import AppKit
import SwiftUI
import VibeBuddyMacCore

@MainActor
final class GlanceWindow {
    private let panel: NSPanel
    private let hosting: NSHostingView<GlanceView>

    init(model: MenuBarModel) {
        let mode = GlanceMode.from(topInset: NSScreen.main?.safeAreaInsets.top ?? 0)
        hosting = NSHostingView(rootView: GlanceView(model: model, mode: mode))
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 220, height: mode == .notch ? 38 : 30),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.contentView = hosting
        reposition()
        panel.orderFrontRegardless()
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.reposition() }
        }
    }

    func reposition() {
        guard let screen = NSScreen.main else { return }
        let size = hosting.fittingSize
        let w = max(size.width, 140), h = max(size.height, 28)
        let x = screen.frame.midX - w / 2
        let y = screen.frame.maxY - h
        panel.setFrame(NSRect(x: x, y: y, width: w, height: h), display: true)
    }
}
