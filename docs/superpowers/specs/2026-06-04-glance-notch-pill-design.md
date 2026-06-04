# Glance surface (notch + pill) — design

**Date:** 2026-06-04
**Status:** Approved (design locked: notch overlay on notch Macs, top-center pill on non-notch)
**Sub-project of the Mac-app parity epic.** Adapts fayazara `macos-app-skills/notch-ui` **patterns** (no-license → study/adapt, our own Swift).

## Goal
An always-there ambient status glance at the top-center of the screen: shows the 🟠 needsResponse / ⏳ working / ✅ done counts at a glance, and expands on hover/click into the session list + any pending approve/deny. On notch MacBooks it renders as a Dynamic-Island-style shape flush with the hardware notch; on non-notch Macs (Mac mini / Studio / iMac) it's the same component as a rounded pill floating top-center. The menu-bar icon and the dashboard hotkey remain on all Macs.

## In scope
- `GlanceWindow` — a borderless, transparent, **non-activating** `NSPanel` at `CGShieldingWindowLevel`, top-center via `screen.frame` (not `visibleFrame`), `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]`. Accepts mouse (hover/click) — NOT click-through (it's interactive).
- `NotchShape` — SwiftUI `Shape`: concave Bézier "ears" at top corners + convex rounded bottom corners, animatable radii. Used on notch Macs.
- **Notch detection**: `NSScreen.main?.safeAreaInsets.top ?? 0 > 0` → notch Mac. Else pill mode (a plain `Capsule()`/rounded-rect, small top gap).
- Collapsed state: compact counts (orange/blue/green dots + numbers), black fill on notch / translucent material on pill.
- Expanded state (on hover, spring-animated): the session list grouped needsResponse/working/done; a session with `pendingApproval` shows the command + Approve/Deny (calls `MenuBarModel.decide`, reusing the built backend).
- Observes the same in-process `MenuBarModel.sessions`.

## Out of scope / stubs
- Jump-back button — **stubbed** (sub-project 2).
- A settings toggle to hide the glance / per-screen choice — later.
- Multi-monitor: render on `NSScreen.main` only for v1 (note as a known limitation).

## Architecture
1. `NotchShape.swift` (VibeBuddyMacApp) — the shape. Pure SwiftUI; visual.
2. `GlanceWindow.swift` (VibeBuddyMacApp) — `NSPanel` subclass: config above, `NSHostingView(rootView: GlanceView(model:))`, positioning helper using `screen.frame` top-center, re-position on `NSApplication.didChangeScreenParametersNotification`.
3. `GlanceView.swift` (VibeBuddyMacApp) — the content: `@State hovering`; collapsed counts ↔ expanded list, `.background(NotchShape().fill(.black))` on notch / `.background(.regularMaterial, in: Capsule())` on pill; `.animation(.spring(...), value: hovering)`. Reuses `SessionGroups` (Kit) for grouping and `MenuBarModel.decide` for approve/deny.
4. Notch detection helper (small, testable): `GlanceMode.current(for: NSScreen?) -> .notch | .pill` based on `safeAreaInsets.top`.
5. Wiring: `MenuBarModel` (or `AppDelegate`) creates/owns the `GlanceWindow` on launch and shows it.

## Interaction
- Non-activating panel → never steals focus from your editor.
- Hover expands; mouse-leave collapses (small delay to avoid flicker).
- Approve/Deny inside the expanded glance → `model.decide` (same path as dashboard/phone).

## Data flow
`SessionStore` → `MenuBarModel.sessions` (polled) → `GlanceView` renders counts/list. Approve → `model.decide` → registry resolve (built backend).

## Testing
- **Unit (testable):** `GlanceMode.current(for:)` notch-vs-pill decision (inject a fake `safeAreaInsets.top`); counts derivation (reuse `SessionGroups`, already tested).
- **Build + live:** the `NSPanel`, `NotchShape` rendering, positioning, hover-expand, multi-screen reposition — verified by build + running on the notch MacBook (notch mode) and ideally an external display (pill mode). The `NotchShape` path is visual; not unit-tested.

## Known risks (flagged for implementers)
- `NSPanel` at `CGShieldingWindowLevel` + SwiftUI hosting + accepting mouse while non-activating is the fiddly part; get the panel `styleMask`/`level`/`collectionBehavior` right (see notch-ui pattern).
- `safeAreaInsets` on `NSScreen` is the notch signal (macOS 12+); verify it's nonzero on the notch MacBook at runtime.
- Positioning must use `screen.frame` (includes the menu-bar/notch band), not `visibleFrame`.
- Keep the glance from overlapping the menu-bar clock/controls — center width should be modest when collapsed.

## Non-goals
Jump-back (stub), hide/settings toggle, multi-monitor fan-out, the liquid-glass settings window (separate sub-project).
