# iOS pet is a pixel cat; Mac keeps the robot

**Status:** Superseded in part (2026-06-06, 2026-09-05) — see the *Amendments*
below. Originally Accepted (2026-06-05), amends ADR-0006.

> **Amendment 2 (2026-09-05): the pixel cat retires; the pet is the icon's cat.**
> The app icon was redesigned as a white cat with green inner ears and eyes on
> slate blue (Mac, iOS and Watch icons, commit `79d5e89`). The 13-wide pixel
> cat no longer matched the character on the home screen, so every surface now
> draws that cat instead, still **entirely in code**:
> - One geometry lives in the Kit: `BuddyCatFace` / `BuddyCat`
>   (`VibeBuddyKit/Sources/VibeBuddyKit/BuddyCat.swift`), a 52 × 60 unit canvas
>   of ellipses and rounded ear wedges. The four former renderers (`PetFace` on
>   iOS and Mac, `WatchCat`, `ActivityCat`) keep only size, clock and surface
>   decisions and no longer carry their own grids.
> - **Colour has two channels that never share a value.** `BuddyCat.accent`
>   (inner ears, belly) is the identity colour, sampled from the icon and the one
>   constant to change if the brand colour moves. The eyes carry the status colour
>   only for attention states (`requiresInput`, `thinking`, `error` tokens);
>   resting and done eyes, the mouth and the open-mouth cavity are a fixed ink
>   (`#445571`), sleeping eyes the lid grey. `TaskStatusColorToken` is unchanged:
>   its white `idle` would vanish on a white cat and `completeUnread`'s green
>   fails contrast on it, so `done` is said with closed happy arcs, not colour.
> - **Size ladder.** Below 34 pt the body and mouth are dropped (compact Dynamic
>   Island, collapsed notch glance, Watch header); below 28 pt only head, ears and
>   eyes remain. The menu-bar mark is the same head rendered once as a monochrome
>   template `NSImage` with punched eyes.
> - Motion is unchanged: iOS and Mac blink / flap / bob at 10 fps (Reduce Motion
>   stops the blink and bob); Watch, widget and Live Activity stay static.
> - Ears are rounded wedges, not triangles — pointed ears read as a different
>   character next to the icon.

> **Amendment (2026-06-06): the cat is now on _both_ platforms.** Per a product
> call, macOS drops the robot and adopts the same pixel cat as iOS, so the pet
> identity is unified everywhere:
> - **macOS notch glance + dashboard header** (`VibeBuddyMacApp/Sources/PetFace.swift`)
>   now render the identical 13-wide pixel-cat grid (white in the dark glance,
>   `.primary` on a card; eyes carry the status accent), replacing the ASCII robot.
> - **macOS menu-bar mark** (`MenuBarGlyph.cat` in `VibeBuddyMenuBarApp.swift`) is a
>   cat-head template silhouette (rounded head + triangle ears + punched eyes),
>   replacing the robot-head glyph.
> - **iOS app icon** (`VibeBuddyApp/Tools/make_app_icon.py` → `AppIcon.appiconset`)
>   is a code-drawn kawaii cat (white cat, green eyes, dark slate), replacing the
>   three-bar mark that read as a paw print on the home screen.
>
> Everything below describes the original iOS-only decision; the "Mac keeps the
> robot" rationale no longer holds. Still **0 bundled artwork** except the app
> icon raster (required by the platform), which is itself generated from code.

ADR-0006 made the pet an all-code-drawn **robot** on both platforms. We now
diverge the pet's *identity per platform*: **iOS** renders a **pixel
black-and-white cat** (`PetFace` in `VibeBuddyApp`), while **macOS keeps the
robot** (`PetFace` in `VibeBuddyMacApp`). The shared mood model
(`BuddyState`/`BuddyAccent` in the Kit) is unchanged — only the rendering differs.

## Why

- The phone wanted a warmer, more characterful mascot; the desk/menu-bar context
  suits the robot's neutral, utilitarian look.
- The earlier iOS build still showed a blue `pawprint` SF Symbol for the working
  state, which reads as the Baidu logo — replacing the whole iOS pet removes that
  and gives iOS its own identity.

## Consequences

- Still **0 bundled artwork**: the cat is drawn in code (SwiftUI `Canvas`, a
  13-wide pixel grid), so ADR-0006's App-Store / asset-licensing safety holds.
- The body is `Color.primary` (black in light mode, white in dark); the eyes
  carry the status accent colour, so the at-a-glance status signal survives the
  "black & white" silhouette.
- The two platforms no longer share a single pet visual — acceptable; the pet is
  a per-platform presentation layer over one shared `BuddyState`.
- The iOS **Live Activity / Dynamic Island** also uses the cat
  (`ActivityPixelCat`, a static Kit-free version — a white body on the activity's
  dark surface), so the iOS pet identity is consistent everywhere.
