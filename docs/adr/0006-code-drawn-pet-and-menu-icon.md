# All-code-drawn pet and template menu-bar icon

**Status:** Accepted (2026-06-05)

The pet (an ASCII robot) and the macOS menu-bar icon are drawn entirely in code —
SwiftUI / `Canvas` for the pet, a template `NSImage` for the menu icon — with no
bundled third-party artwork. This avoids any asset-licensing question and is
App-Store-review-safe by construction. It deliberately replaced an earlier Lottie
cat (a dependency + bundled JSON) and a mood-morphing SF Symbol menu icon (no
stable identity); the menu icon now keeps one silhouette and signals state via a
badge, not a shape change.
