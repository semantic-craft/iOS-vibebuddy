import AppKit
import SwiftUI
import VibeBuddyKit
import VibeBuddyMacCore

/// How much of the sidebar's lettering a row draws at the current width:
/// full at every labeled width, a ramp while a drag crosses the collapse
/// threshold, none on the icon-only rail (where titles move into tooltips).
struct SidebarLabelStyle: Equatable {
    var opacity: CGFloat = 1
    var iconOnly = false

    static func at(width: CGFloat) -> SidebarLabelStyle {
        SidebarLabelStyle(opacity: DashboardSidebarWidth.labelOpacity(at: width),
                          iconOnly: DashboardSidebarWidth.isIconOnly(at: width))
    }
}

private struct SidebarLabelStyleKey: EnvironmentKey {
    static let defaultValue = SidebarLabelStyle()
}

extension EnvironmentValues {
    var sidebarLabels: SidebarLabelStyle {
        get { self[SidebarLabelStyleKey.self] }
        set { self[SidebarLabelStyleKey.self] = newValue }
    }
}

/// The sidebar's draggable right edge, as Cursor resizes its sidebar: a
/// 10 pt strip over the hairline that shows a short pill at mid-height and
/// the ↔ cursor on hover, a "Drag to resize" tip after a beat, follows the
/// pointer while dragging, and toggles the two settled widths on a
/// double-click. AppKit handles the pointer (cursor rects, click count,
/// tracking) so the cursor never gets stuck and a double-click never starts
/// a drag; SwiftUI draws the pill and the tip in the app's tokens.
struct SidebarResizeHandle: View {
    /// True while the pointer is down on the edge; keeps the pill up after
    /// the pointer has left the strip.
    let dragging: Bool
    let iconOnly: Bool
    var onDragBegan: () -> Void
    /// Horizontal distance from where the drag began, in points.
    var onDragChanged: (CGFloat) -> Void
    var onDragEnded: () -> Void
    var onDoubleClick: () -> Void

    @State private var hovering = false
    @State private var tipShown = false
    @State private var tipTimer: Task<Void, Never>?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var lit: Bool { hovering || dragging }

    var body: some View {
        SidebarEdgeTracker(
            hover: { inside in
                hovering = inside
                scheduleTip(inside && !dragging)
            },
            dragBegan: { scheduleTip(false); onDragBegan() },
            dragChanged: onDragChanged,
            dragEnded: onDragEnded,
            doubleClick: { scheduleTip(false); onDoubleClick() },
            accessibilityValue: iconOnly ? String(localized: "Icons only") : String(localized: "Labeled"))
        .frame(width: 10)
        .overlay {
            // The pill sits on the hairline, so it reads as part of the edge.
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(dragging ? MacTheme.accent : MacTheme.ink.opacity(0.35))
                .frame(width: 4, height: 36)
                .opacity(lit ? 1 : 0)
                .scaleEffect(x: 1, y: lit ? 1 : 0.6)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: lit)
                .allowsHitTesting(false)
        }
        .overlay(alignment: .leading) {
            if tipShown {
                Text("Drag to resize")
                    .font(MacTheme.font(10.5, .medium)).foregroundStyle(MacTheme.ink2)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(MacTheme.bg3, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(MacTheme.line, lineWidth: CompanionType.hairline))
                    .fixedSize()
                    .offset(x: 14)
                    .transition(reduceMotion ? .identity : .opacity.combined(with: .offset(x: -3)))
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .onDisappear { tipTimer?.cancel() }
    }

    /// Cursor shows its resize tip after a short hover, never on the way past.
    private func scheduleTip(_ wanted: Bool) {
        tipTimer?.cancel()
        guard wanted else {
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.1)) { tipShown = false }
            return
        }
        tipTimer = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 450_000_000)
            guard !Task.isCancelled, hovering, !dragging else { return }
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.12)) { tipShown = true }
        }
    }
}

/// The transparent AppKit strip under the handle. Cursor rects give the ↔
/// cursor for free and keep it through a drag; `clickCount` separates a
/// double-click from the first press of a drag.
private struct SidebarEdgeTracker: NSViewRepresentable {
    var hover: (Bool) -> Void
    var dragBegan: () -> Void
    var dragChanged: (CGFloat) -> Void
    var dragEnded: () -> Void
    var doubleClick: () -> Void
    var accessibilityValue: String

    func makeNSView(context: Context) -> EdgeView {
        let view = EdgeView()
        apply(to: view)
        return view
    }

    func updateNSView(_ view: EdgeView, context: Context) { apply(to: view) }

    private func apply(to view: EdgeView) {
        view.hover = hover
        view.dragBegan = dragBegan
        view.dragChanged = dragChanged
        view.dragEnded = dragEnded
        view.doubleClick = doubleClick
        view.valueDescription = accessibilityValue
    }

    final class EdgeView: NSView {
        var hover: (Bool) -> Void = { _ in }
        var dragBegan: () -> Void = {}
        var dragChanged: (CGFloat) -> Void = { _ in }
        var dragEnded: () -> Void = {}
        var doubleClick: () -> Void = {}
        var valueDescription = ""
        private var tracking: NSTrackingArea?
        private var downX: CGFloat = 0
        private var dragging = false

        override var acceptsFirstResponder: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let tracking { removeTrackingArea(tracking) }
            let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                      owner: self, userInfo: nil)
            addTrackingArea(area)
            tracking = area
        }

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .resizeLeftRight)
        }

        override func layout() {
            super.layout()
            window?.invalidateCursorRects(for: self)
        }

        override func mouseEntered(with event: NSEvent) { hover(true) }
        override func mouseExited(with event: NSEvent) { hover(false) }

        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 {
                doubleClick()
                return
            }
            downX = event.locationInWindow.x
            dragging = true
            dragBegan()
        }

        override func mouseDragged(with event: NSEvent) {
            guard dragging else { return }
            dragChanged(event.locationInWindow.x - downX)
        }

        override func mouseUp(with event: NSEvent) {
            guard dragging else { return }
            dragging = false
            dragEnded()
            // The release snaps the edge away from (or under) a pointer that
            // has not moved, and the window server sends no enter/exit for
            // that; settle the hover by hand once the spring has landed.
            syncHover()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in self?.syncHover() }
        }

        private func syncHover() {
            guard !dragging, let window else { return }
            hover(bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil)))
        }

        // MARK: Accessibility — a splitter, like NSSplitView's divider.

        override func isAccessibilityElement() -> Bool { true }
        override func accessibilityRole() -> NSAccessibility.Role? { .splitter }
        override func accessibilityLabel() -> String? { String(localized: "Sidebar width") }
        override func accessibilityValue() -> Any? { valueDescription }
        override func accessibilityHelp() -> String? { String(localized: "Drag to resize; double-click to collapse or expand the sidebar") }
        override func accessibilityPerformPress() -> Bool {
            doubleClick()
            return true
        }
    }
}
