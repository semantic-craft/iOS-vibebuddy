# The Mac glance follows the Dynamic Island's grammar; cards replace banners while it is on screen

**Status:** Accepted (2026-09-05).

## Context

On a MacBook with a camera housing the glance placed a 220×38pt black
`NotchShape` at the top centre of the screen with the pet and counts centred in
it. The 14" housing is 185×32pt and the 16" one is 220×38pt, so the panel
coincided with the housing and its content sat behind the camera: the user saw a
slightly wider notch and nothing else. The panel was also re-measured and
re-framed on every state change, which had already tripped AppKit's display
cycle once.

Research across the mature notch apps (boring.notch, DynamicNotchKit,
NotchDrop, ghnotch) shows one converged model, which is the iPhone's: the
housing is a black anchor that is never drawn into; compact content lives in a
wing either side (leading / trailing); anything taller drops below; one
transparent panel is pre-sized to the largest state and never resized; the shape
flares its top corners outward so it meets the menu bar where the housing does.

Four directions were drawn (`.scratch` canvas "VibeBuddy 灵动岛方案"). The user
chose **A (invisible island) + D (event cards)**.

## Decision

1. **Geometry comes from the screen, not constants.** `NotchGeometry.from` reads
   `auxiliaryTopLeftArea` / `auxiliaryTopRightArea` / `safeAreaInsets.top`;
   `nil` auxiliary areas mean no notch (`GlanceLayout.pill`). The panel is one
   600×440pt transparent `NSPanel`, top-centre of the menu-bar screen, never
   resized; the window server hit-tests the transparent surround away so the
   menu bar beside the housing stays clickable.
2. **Four modes, content never inside the housing.** `idle` draws only the
   housing-sized anchor (invisible behind the camera). `compact` grows a wing
   each side: the pet on the left, the single primary state + count on the right
   (`TaskPresentationSummary.primaryState`; voice badge while the companion is
   live). `card` and `expanded` drop a body below the housing, ≤ 2× its width.
   Uneven wings offset the island so the gap stays over the real housing.
   Radii: 6/14pt compact, 15/20pt tall; spring 0.36 / 0.8; haptic on hover;
   hover opens after 200ms dwell, closes 250ms after leaving.
3. **Cards replace banners while the glance is showing.** `GlanceAttentionRouter`
   sits in front of `UserNotificationsNotifier`: a `SoundPolicy` cue becomes a
   `GlanceCard` (8s actionable / 2.5s passive, held while hovered, withdrawn
   early when its wait resolves — `GlanceCardQueue`, pure and tested) and the
   pack's sound plays via `NSSound`. With the glance hidden the cue falls through
   to the banner unchanged. The "notify" and "sound" switches govern both paths.
4. **Notchless screens hang a pill 6pt under the menu bar** with the same
   content; it is always visible (there is no housing to hide in).

## Consequences

- The pet and the counts are visible on every MacBook; on a notch Mac the
  default is nothing until there is something to say.
- Approvals can be answered without leaving the current window; the macOS
  banner is no longer posted for session cues while the glance is up
  (delivery is still recorded as a local delivery).
- `GlanceMode` and the measure-and-reframe window code are gone. QA on a
  notchless Mac uses `VIBEBUDDY_FAKE_NOTCH=185x32`.

## Amendment (2026-09-07): fixed menu-bar entry

The menu-bar icon is a stable cat mark opening the Dashboard/Settings menu,
with no state or count by default. General Settings offers an independent
"Show task status in menu bar" switch (default off) that adds the primary
state's dot and count. The Glance owns ambient status, counts and
actionable alerts so the two persistent surfaces do not repeat that summary.
Both remain enabled by default, with independent visibility switches. Hiding
the Glance keeps the existing macOS notification path; it does not add status
back to the menu-bar icon automatically. The task-status preference is independent
of Glance visibility. Details inside the opened menu remain available.


## Amendment (2026-09-09): compact width never exceeds the housing

The owner rejected lateral growth, including the proposed 253–261 pt compact
wings on a 185 pt housing. The compact Glance now reserves the camera height
and displays the cat and primary state/count in a 28 pt strip immediately below
it. Its width is exactly the screen-derived housing width, with no horizontal
shape allowance or wings. Idle returns to the housing-sized anchor.

This supersedes the compact-wing geometry and asymmetric offset in decision 2.
The change limits width; the compact strip adds height below the camera so its
content is visible. Card and expanded modes retain their existing wider bodies
below the housing. The camera area remains empty in every mode.

The compact count follows TaskPresentationSummary's primary state, caps visual
counts at 99+, and exposes the exact count and state through accessibility and
help text. Active voice uses a bounded symbol with the full state in accessibility
and expanded content. A clipped voice outline cannot paint outside the shape.
The stable transparent panel and the notchless pill remain the existing model.

## New decision (2026-09-13): keep the task list while a decision waits

ADR-0020 revises approval placement: the expanded Glance always retains its task
list. A waiting row expands an inline decision with the available actions; it
does not replace the entire list. This is a new decision, not a description of
what the original ADR already guaranteed. Event-card timing and geometry remain.
The menu badge defaults on absent an explicit saved choice and counts Needs you
plus unread Done; the original default-off decision above is superseded.

## Amendment (2026-09-15): compact content beside the housing at its actual height

After inspecting the physical display and mature implementations, the owner
approved compact content beside the camera, with no added height below it.
This supersedes September 9's width restriction and 28 pt strip.

The screen-derived housing gap remains centered. Each wing uses its content
width plus 8 pt padding on each side, measured with onGeometryChange. Half the
trailing-minus-leading width offsets the island to keep the camera gap centered.
Widths therefore follow the status/avatar and count/voice symbol, not the Mac
model or a fixed slot size. Both wings are
bounded by the actual housing height, independent of Dynamic Type and the card
size preference. Idle remains housing-only. Collapsed voice does not paint an
outline or shadow beyond that height. Cards, expansion and notchless pills keep
their existing behavior.

References inspected: [DynamicNotchKit compact layout](https://github.com/MrKai77/DynamicNotchKit/blob/cd0b3e52d537db115ad3a9d89601f20e0bee8d27/Sources/DynamicNotchKit/Views/NotchView.swift)
and [Boring Notch screen sizing](https://github.com/TheBoredTeam/boring.notch/blob/85af174f3b3894996152c5402f6569a987d86694/boringNotch/sizing/matters.swift).


## Amendment (2026-10-01): every notch state matches the housing width

The owner reports that the expanded black notch is too wide on the new MacBook
Pro and requests a design based on Apple's guidance. This supersedes September
15's lateral wings: idle remains housing-only; compact reserves the entire
system-reported camera area and puts status in a 28 pt strip immediately below
it, exactly as wide as the housing, with no horizontal flare or offset. Status
and voice keep their existing accessible labels. The owner explicitly requires
**all states** to match the hardware width: cards and expanded lists also use
that exact width, with vertically stacked actions and scrollable content below
the camera. The shape and voice outline are clipped to that width; no flare,
shadow or size preference may widen it. Notchless pills retain their layout.

Apple's [Layout HIG](https://developer.apple.com/design/human-interface-guidelines/layout)
and [NSScreen.safeAreaInsets](https://developer.apple.com/documentation/appkit/nsscreen/safeareainsets)
require avoiding obscured content; [auxiliaryTopLeftArea](https://developer.apple.com/documentation/appkit/nsscreen/auxiliarytopleftarea-uglc)
describes the usable area beside the camera. These APIs supply geometry in
points for the current screen configuration. The app continues deriving housing
width from those areas and height from the top inset, without model/year pixel
constants. The 28 pt strip and no-widening choice are this app's design, not an
Apple-prescribed notch size. The tradeoff is added height while tasks are active.


## Amendment (2026-10-01): prefer a visible hardware-notch display

The owner accepted the display-adaptation prototype. This supersedes decision
1's fixed menu-bar-screen anchor: choose the first available screen with valid
NSScreen camera geometry; if none exists, choose NSScreen.screens.first and use
the existing floating capsule below its menu bar. Keyboard focus does not move
the Glance. Screen-parameter changes reselect the screen and recompute geometry,
so closing the lid falls back to an external screen and reopening restores the
hardware notch. With no available screens, hide the panel until one returns;
a user-hidden Glance stays hidden through these changes. Keep one panel only.

The fake-notch QA override changes rendering only, never hardware selection.
The accepted prototype is preserved on branch `codex/prototype-glance-adaptation`
(commit `bbce9efc4107`) at
`VibeBuddyMacApp/Prototypes/GlanceAdaptation.prototype.html`. It is a throwaway
reference kept out of main, not an app resource or runtime dependency.
