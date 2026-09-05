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
