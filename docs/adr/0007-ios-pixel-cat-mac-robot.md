# iOS pet is a pixel cat; Mac keeps the robot

**Status:** Superseded in part (2026-06-06) — see *Amendment* below. Originally
Accepted (2026-06-05), amends ADR-0006.

> **Amendment (2026-06-06): the cat is now on _both_ platforms.** Per a product
> call, macOS drops the robot and adopts the same pixel cat as iOS, so the pet
> identity is unified everywhere:
> - **macOS notch glance + dashboard header** (`VibeBuddyMacApp/Sources/PetFace.swift`)
>   now render the identical 13-wide pixel-cat grid (white in the dark glance,
>   `.primary` on a card; eyes carry the status accent), replacing the ASCII robot.
> - **macOS menu-bar mark** (`MenuBarGlyph.cat` in `VibeBuddyMenuBarApp.swift`) is a
>   cat-head template silhouette (rounded head + triangle ears + punched eyes),
>   replacing the robot-head glyph.
> - **App icon** (iOS, macOS, watchOS) is one 1024 px raster: the white cat with
>   green ears and eyes on slate blue, designed with the ip-as-logo skill (PR #30).
>   The iOS `icon_1024.png` is the master; `VibeBuddyApp/Tools/make_app_icon.py`
>   derives the macOS size ladder, the Watch icon and the README renders from it.
>
> Everything below describes the original iOS-only decision; the "Mac keeps the
> robot" rationale no longer holds. Still **0 bundled artwork** except the app
> icon raster (required by the platform), which is no longer drawn in code.

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
