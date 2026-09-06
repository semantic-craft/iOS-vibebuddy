// Run on a logged-in Mac from the repo root (opens temporary test windows):
// swiftc -swift-version 6 VibeBuddyMacApp/Sources/AppActivationPolicy.swift \
//   VibeBuddyMacApp/Sources/AppWindows.swift tools/window-recovery-qa/main.swift \
//   -o /tmp/vibebuddy-window-qa && /tmp/vibebuddy-window-qa
// Uses test content, no daemon, real sessions, or VibeBuddy preference domain.
import AppKit
import SwiftUI

final class FocusablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override func constrainFrameRect(_ frame: NSRect, to screen: NSScreen?) -> NSRect { frame }
}

let app = NSApplication.shared
func pump() { RunLoop.current.run(until: Date().addingTimeInterval(0.15)) }
func check(_ ok: @autoclosure () -> Bool, _ label: String) {
    guard ok() else { print("FAIL: \(label)"); exit(1) }
    print("PASS: \(label)")
}
let panel = FocusablePanel(contentRect: NSRect(x: 20, y: 300, width: 600, height: 440), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
panel.isReleasedWhenClosed = false
panel.isOpaque = false
panel.backgroundColor = .clear
panel.level = .mainMenu + 3
panel.orderFrontRegardless()
let anchor = panel.frame
let windows = AppWindows(dashboard: AnyView(Text("Window regression probe")), settings: AnyView(Text("Settings regression probe")))
windows.showDashboard(); pump()
let dashboard = windows.dashboardWindow!
check(panel.frame == anchor, "Opening dashboard preserves focusable Glance panel frame")
check(dashboard.isVisible, "Dashboard opens")
for _ in 0..<5 { windows.showDashboard() }
pump()
check(windows.dashboardWindow === dashboard, "Repeated open reuses dashboard identity")
check(panel.frame == anchor, "Repeated activation preserves Glance frame")
windows.showSettings(); pump()
let settings = windows.settingsWindow!
check(settings !== dashboard && settings.isVisible, "Settings has separate visible window")
dashboard.close(); pump()
check(app.activationPolicy() == .regular, "Closing dashboard keeps Dock while settings remains")
settings.close(); pump()
check(app.activationPolicy() == .accessory, "Closing last ordinary window hides Dock despite visible panel")
windows.showDashboard(); pump()
check(windows.dashboardWindow === dashboard && dashboard.isVisible, "Closed dashboard reopens with same identity")
dashboard.miniaturize(nil); pump()
check(dashboard.isMiniaturized, "Dashboard minimizes")
windows.showDashboard(); pump()
check(!dashboard.isMiniaturized && dashboard.isVisible, "Opening minimized dashboard restores it")
check(panel.frame == anchor, "Full sequence never moves Glance panel")
dashboard.close(); settings.close(); panel.close(); pump()
print("All window identity and lifecycle checks passed")
