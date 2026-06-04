# Dashboard window — design

**Date:** 2026-06-04
**Status:** Approved for implementation (layout confirmed via visual mockup)
**Sub-project 1 of the "Mac-app parity" epic** (others: jump-back, glance/notch, +8 agents, in-app hook settings, session persistence — each its own spec).

## Goal

A real macOS **window** in the menu-bar app for browsing every session, selecting with the keyboard, and acting on the selected one (approve/deny on the Mac; jump-back stubbed for now). Opened with a global hotkey (⌥Space) or from the menu-bar menu. Native macOS look (`NavigationSplitView`), matching the macos_ui / Changes aesthetic.

## In scope
- A `Window` scene (3-pane `NavigationSplitView`): sidebar (status + agent filter) · session list · detail.
- Reads the **same in-process `SessionStore`** the menu-bar already polls (no networking — the menu-bar app IS the daemon).
- Keyboard: ↑/↓ select, ⌘1/2/3 switch status group, ⌘F focus search, **A** approve, **D** deny, **⏎** jump (stub), **⌃⌥⇧⌘'** global open.
- **Mac-side approval**: when a session has a `pendingApproval`, the detail pane shows the command + 批准/拒绝; clicking resolves the held `/approval` request **locally** via the shared `ApprovalRegistry` (reusing the already-built matcher/registry/routes). No phone needed.
- Search box filters the list by project/summary.
- Global hotkey to open/focus the window.

## Out of scope (other sub-projects / stubs)
- **Jump-back to terminal** — the `[跳回终端]` button is present but **stubbed** (disabled or "即将支持"); real impl is sub-project 2.
- **Glance / notch surface** — separate sub-project; this is the window only.
- **+8 agents, persistence, in-app hook install, sound config** — separate sub-projects. The window works with the current live in-memory sessions (Claude Code + Codex).
- Transcript viewer — `[查看 transcript]` opens the transcript file in the default app (Finder/editor); no in-app viewer.

## Architecture

The menu-bar app (`VibeBuddyMacApp`) currently has only a `MenuBarExtra` scene and a `MenuBarModel` that owns the `SessionStore` + `VibeBuddyServer` and polls snapshots. Additions:

1. **Shared `ApprovalRegistry`** — `MenuBarModel` creates one `ApprovalRegistry` and passes it into `VibeBuddyServer(... approvalRegistry:)` (the init param already exists), and keeps a reference so the window can resolve decisions locally. `MenuBarModel` gains `func decide(_ approvalId: String, approve: Bool)` → `await registry.resolve(id:, with:)`.

2. **`DashboardWindow` scene** (new `Window` in `VibeBuddyMenuBarApp.body`), gated so only one instance, titled "vibebuddy". Holds a `DashboardView` bound to the shared `MenuBarModel`.

3. **`DashboardView`** = `NavigationSplitView`:
   - **Sidebar**: a `List` with two sections — *状态* (需回应/进行中/已完成, each with a live count from `SessionGroups`) and *Agent* (Claude Code, Codex; greyed future agents are NOT shown — only agents actually present). Selection drives the filter.
   - **Content (middle)**: the filtered, attention-sorted session list (reuse `SessionGroups`/`AttentionDiff` sort). `List(selection:)` bound to the selected session id for keyboard ↑/↓.
   - **Detail**: selected session — project, agent/model/tokens chips, summary; if `pendingApproval != nil`, the command preview + 批准/拒绝 buttons (call `model.decide`); a stubbed 跳回终端 button; a 查看 transcript button (opens the file).

4. **Global hotkey** (default **⌃⌥⇧⌘'**, rebindable): use the `KeyboardShortcuts` SPM package (Sindre Sorhus, MIT) — gives system-wide hotkey via `RegisterEventHotKey` (no Accessibility prompt) and a built-in rebinding UI for later. On trigger → `NSApp.activate` + `openWindow(id: "dashboard")`. (Alternative considered: raw Carbon `RegisterEventHotKey` — no dependency but verbose; `KeyboardShortcuts` is the cleaner choice and a single small dep.)

5. **State**: `DashboardView` observes `MenuBarModel.sessions` (already `@Published`, refreshed by the 2s poll + broadcasts). Filtering/selection is `@State` in the view. No new data source.

## Data flow
`SessionStore` (in-process) → `MenuBarModel.sessions` (polled) → `DashboardView` groups/filters/sorts for display. Approve/deny: button → `model.decide(id, approve)` → `registry.resolve` → the held `/approval` request returns the decision → the daemon's `endApproval` clears `pendingApproval` → next poll updates the window.

## Error handling
- No sessions → empty-state ("启动一个会话,它会出现在这里").
- A `pendingApproval` whose id is already resolved/expired → `resolve` is a no-op (registry is idempotent); the button just clears on next poll.
- Global hotkey registration failure → log + the menu-bar menu still opens the window (hotkey is a convenience, not the only entry).

## Testing
- **Unit (Kit/Core, testable):** `SessionGroups` filtering/sorting already tested. Add tests for any new pure filter/search predicate (e.g., a `filter(sessions:by:query:)` helper) — search matches project/summary case-insensitively; status/agent filters select correctly.
- **Build + live:** the window UI, `NavigationSplitView`, global hotkey, and `model.decide` wiring are verified by building the app and exercising it (open via hotkey; with the `--approval` hook enabled, trigger a non-allow command, approve in the window, confirm the command runs). The Mac-approval path reuses the already-tested registry/routes.

## Non-goals / explicit deferrals
Jump-back (stub), glance/notch, more agents, persistence, in-app hook settings, sound config, in-app transcript viewer. Each is a later sub-project.

## Resolved decisions
- Global hotkey default: **⌃⌥⇧⌘ + '** (hyper-key combo, zero conflict risk; rebindable via `KeyboardShortcuts`).
- Sidebar agent filter: **present-only** — lists just the agents that have actually appeared.
