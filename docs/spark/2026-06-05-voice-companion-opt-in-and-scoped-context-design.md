# Voice Companion — opt-in master switch + scoped session context

**Status:** Spec (2026-06-05) · brainstormed via `/spark` + `/grill-me`

## Problem

The voice companion is powerful but has two gaps:

1. **No informed-consent gate.** Today the only thing standing between "tap the pet"
   and "mic open + session context streaming to a third-party provider" is *having
   a provider key* (`VoiceChat.isAvailable`). A tap silently opens the mic and ships
   the user's session context to OpenAI / Google / Alibaba. There is no deliberate,
   visible "I'm turning this on" moment.
2. **No control over which sessions the buddy sees.** `VoicePrompt.systemPrompt`
   is built from *all* live sessions at call start. For a rubber-duck "聊思路"
   conversation the user wants to point the buddy at a specific thread (or a few),
   and to keep some sessions out for privacy.

This spec adds **one opt-in master switch** (the consent gate) and, under it,
**per-session scope control**.

## Core scenario

Rubber-duck / advisor: the user taps the pet and talks through their approach,
with the buddy grounded in the (chosen) sessions as background context.

## Design decisions (from the grill)

| Decision | Choice | Why |
|---|---|---|
| What's missing | A deliberate master enable / consent gate | Tap → live is too implicit for audio + context leaving the device |
| Master switch behaviour | Persistent, **default OFF**, opt-in | Default-off is what makes it actually "informed" |
| Master switch home | **Settings** (toggle + disclosure together) | Consent belongs next to the disclosure; keeps the pet area uncluttered |
| Off-tap behaviour | Tap the off pet → **inline consent sheet → Enable** (does *not* auto-open the mic) | You tapped to talk; hunting in Settings is friction. Consent still persists to the Settings toggle |
| Switch vs context | **One master switch** gates voice **and** session context together | One consent moment, not two |
| Scope control | **Per-session "include in buddy" toggle**; none selected = all | Matches "哪些会话" (plural); preserves current all-by-default behaviour |
| Inclusion set | **Multi-select, ephemeral** (in-memory, resets on restart) | Simplest; no stale-ID persistence to manage |
| Context freshness | **Snapshot at call start** (no live refresh) | Matches the current architecture (system prompt fixed per session) |
| Migration | **Hard default-OFF for everyone** (one-time enable after update) | Grandfathering existing-key users to ON defeats the consent change |

## Architecture

Two layers; the master switch is the single privacy gate, the scope toggles
narrow within it.

### Layer 1 — opt-in master switch

- **State:** a persistent `companionEnabled: Bool` (UserDefaults), default `false`.
  Lives in the platform model that owns `VoiceChat` — `MenuBarModel` (Mac),
  `DashboardStore`/app state (iOS). New `VoiceChat.isEnabled` reads it.
- **Gate:** `VoiceChat.toggle()` / `startRealtime()` require `companionEnabled`
  *and* the existing key check. If not enabled, a tap surfaces the consent sheet
  instead of starting.
- **Consent sheet:** the disclosure text (already the footer of the Voice section
  in both `SettingsView`s) + an **Enable** button. Enabling sets `companionEnabled
  = true`; it does **not** auto-start the mic — the next tap starts the call.
- **Settings:** a "Voice companion" toggle at the top of the Voice section in
  `VibeBuddyMacApp/Sources/SettingsView.swift` and
  `VibeBuddyApp/Sources/SettingsView.swift`, bound to `companionEnabled`, with the
  disclosure beneath it. Toggling off **ends any live call**.
- **Pet / header state:** the pet stays the ambient status creature regardless
  (mood unchanged). When disabled, the buddy header reads **"Voice companion off"**
  with a subtle `mic.slash` glyph (in `MacBuddyBar` / iOS `BuddyView`). Live state
  (glance glow + Listening/Speaking badge) is unchanged and separate.

### Layer 2 — scoped session context

- **`BuddyScope` (VibeBuddyKit, pure, unit-tested):**
  ```swift
  enum BuddyScope {
      static func included(from sessions: [AgentSession],
                           selectedIDs: Set<String>) -> [AgentSession]
  }
  ```
  Returns the sessions whose `id` is in `selectedIDs`; **if that intersection is
  empty, returns all `sessions`.** This one rule covers both "none selected = all"
  and "all selected sessions vanished = all."
- **Inclusion state:** `buddySessionIDs: Set<String>` — an in-memory `@Published`
  on `MenuBarModel` (Mac) and `DashboardStore` (iOS), plus `toggleBuddy(_ id:)`.
  Pruned to live session IDs when a snapshot arrives. Not persisted.
- **contextProvider wiring:** the closure handed to `VoiceChat` changes from
  `{ allSessions }` to `{ BuddyScope.included(from: allSessions, selectedIDs: buddySessionIDs) }`.
  `VoicePrompt.systemPrompt` is untouched. Snapshot at call start (existing
  behaviour); per-session content unchanged (status + ~220-char latest snippet).
- **UI — include toggle:** a quiet SF Symbol toggle on each dashboard row
  (`SessionRowView` on Mac, `SessionRow` on iOS), filled when included.
- **UI — scope line:** a small line by the buddy header — **"Buddy: all sessions"**
  or **"Buddy: 2 selected"** — so "none = all" isn't confusing.

## Data flow

```
Settings: enable "Voice companion" (consent)  ──►  companionEnabled = true
tap pet (enabled)                              ──►  startRealtime → talk
tap pet (disabled)                             ──►  consent sheet → Enable (no auto-mic)
per-row include toggle                         ──►  model.toggleBuddy(id)  (buddySessionIDs)
tap pet                                         ──►  contextProvider()
                                                     = BuddyScope.included(allSessions, buddySessionIDs)
                                                ──►  VoicePrompt.systemPrompt(scoped)  ──►  session starts
```

## Edge cases

- **None included → all** (the `BuddyScope` rule).
- **Included session disappears** → pruned on the next snapshot; if all included
  vanish → empty set → all.
- **Toggle scope during a live call** → no effect on the current call (snapshot at
  start); applies next call. A small hint may say so.
- **Disable master switch mid-call** → ends the call.
- **iOS demo mode** → both layers work on the demo sessions.

## Testing

- **`BuddyScopeTests` (Kit):** selected subset; empty selection → all; selection
  with no live match → all; partial match → just the matches.
- Master-switch gate + consent sheet + scope UI: verified by build + a run
  (Simulator / deployed Mac app), both platforms.

## Out of scope (v1)

- **Depth knob** — deepening per-session content beyond the current snippet.
- **Live mid-call context refresh** — pushing updated context during a call.
- **Scope persistence** — the inclusion set is ephemeral by choice.
- **"Voice but zero session context" mode** — a `None` scope state.
- **Glance-row include toggle** — the toggle lives on dashboard rows only.

## Related (already shipped)

- **Hands-free close** (`VoiceCloseIntent`, commit `2dc5b85`) — say "再见 / 关闭 /
  bye" to end the call. Complements the master switch's deliberate enable with a
  low-friction exit.
- **Gemini half-duplex fix** (`HalfDuplexGate`, commit `8b4100a`) — unrelated but
  in the same voice subsystem.
