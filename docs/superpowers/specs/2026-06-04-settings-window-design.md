# vibebuddy — Settings window + configurable global hotkey (design)

**Date:** 2026-06-04 · **Status:** approved (user picked the 3-tab scope)

## Goal
A native macOS Settings window (opened with **Cmd+,**) consolidating the app's preferences, plus a **user-configurable global hotkey** (recorder) for opening the Dashboard. Replaces the ad-hoc toggles scattered in the menu-bar popover.

## Window & entry points
- SwiftUI `Settings { SettingsView(model:) }` scene → native Cmd+, binding + standard Preferences chrome.
- `@Environment(\.openSettings)` "Settings…" buttons in **(a)** the menu-bar popover and **(b)** the Dashboard — so even with the menu-bar icon hidden, `Hyper+'` → Dashboard → Settings is always reachable.
- Layout: top-tab `TabView` (classic Preferences). **Deliberately not** NavigationSplitView (we just fixed a NavigationSplitView/NSHostingView constraint-loop crash — keep Settings simple/stable).

## Tabs & controls
**General**
- Launch at Login — `LaunchAtLogin.set` (already wired).
- Show menu bar icon — `@AppStorage("showMenuBarIcon")` (default true) gates the `MenuBarExtra` scene with an `if` in the App body. Hiding it shows a one-time explanation that the hotkey/glance remain the way back.
- Open-Dashboard global hotkey — recorder; default **Hyper+'** (⌃⌥⇧⌘ + `'`, keyCode 39).

**Glance**
- Show glance — toggles the `GlanceWindow` (orderFront/orderOut).
- Size — Small / Medium / Large (`glanceScale`, already wired).

**Notifications**
- Notify when a session needs response — gates the banner.
- Play sound — gates the notification sound.

## Components & data flow
- **`Hotkey` (VibeBuddyMacCore, pure, TDD):** `{ keyCode: UInt32, cocoaModifiers: UInt, displayKey: String }` + `carbonModifiers: UInt32` (Cocoa→Carbon bit conversion), `displayString` (⌃⌥⇧⌘ + key), `hasModifier`, `Codable`, `static let openDashboardDefault`, `load/save(UserDefaults)`.
- **`GlobalHotkey` (app):** install the Carbon event handler once; `setHotkey(_:)` unregisters the previous `EventHotKeyRef` and registers the new combo; `install()` loads the saved `Hotkey` (or default).
- **`HotkeyRecorderView` (app):** shows `displayString`; "Record" → `NSEvent.addLocalMonitorForEvents([.keyDown])` swallowing events; Esc cancels; bare keys (no modifier) rejected; on capture → `model.setHotkey`.
- **`MenuBarModel` (app):** new published flags load/save via UserDefaults; `setHotkey` persists + re-registers; `setShowGlance` shows/hides the panel.
- **`UserNotificationsNotifier` (app):** reads `notifyOnNeedsResponse` / `playNotificationSound` at notify-time (default true when unset). `NotificationCoordinator` stays pure.

## Testing
- TDD the `Hotkey` pure logic (modifier conversion per bit, display ordering, default, Codable round-trip, hasModifier, load/save round-trip with an injected `UserDefaults(suiteName:)`).
- AppKit/Carbon glue (Settings scene, recorder monitor, MenuBarExtra gating, glance show/hide) verified by build + user smoke test.

## Out of scope (this round)
Pairing tab (QR stays in popover); remote-approval toggle; auto-update. Each its own later sub-project.
