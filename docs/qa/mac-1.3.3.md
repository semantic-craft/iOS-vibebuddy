# macOS 1.3.3 acceptance — 2026-09-07

Source: f7daa73, based on 87c6a84 (PR #120 / 1.3.2). This document and final release-note signing statement do not change executable source.

## Passed

- MacCore: 732 Swift Testing tests; Kit: 307 Swift Testing tests plus 27 XCTest tests. This includes Cursor CLI timeout/cancellation and Grok recovery regressions.
- Independent read-only review: no blocking Standards or Spec findings; no confirmed unused source in the changed area. Removed obsolete always-on status behavior; no compatibility preference keys added.
- Release build, Developer ID signature, hardened runtime, app and DMG notarization/stapling, and Gatekeeper assessment.
- Ran the signed release executable as the primary app with actual Claude/Codex sessions and existing provider logins, without demo data. Health returned ok; the authenticated snapshot contained real Codex and Claude sessions.
- CUA verified General settings: icon on, new task-status switch off by default; toggles on/off. Hiding the icon disables the status control. Glance can be hidden independently.
- Quit and restarted the signed release: task-status on and Glance off persisted independently, health recovered, and live provider data refreshed. Restored icon on, task-status off, Glance on afterwards.
- Actual 13:34 UI: Codex 40%; Claude 1% short / 50% week; Grok 0%; Cursor Models 38% / Other Models 98%. All refreshed, no stale marker at that observation. Percentages are time-specific live readings, not fixed expected values.
- Launching a second release instance returned to the existing dashboard, exited, and left exactly one app process plus healthy service.
- Read-only DMG mount: inner executable SHA-256 matched the exercised signed executable; nested signature verified.

## Verification limits

- CUA exposed app windows and settings but not system status items. The menu glyph pixels and a real camera-notch layout were not visually verified; default/conditional rendering was reviewed in source. This is not a claim of exhaustive visual E2E.
- No real approval was generated solely for this test; unchanged notification routing is covered by existing regression tests, not a new human-perception acceptance.
- No iPhone/Watch build, voice interaction, or Sparkle replacement installation was performed. They are outside the changed behavior. The existing installed 1.3.2 was restarted after candidate E2E; /Applications was not replaced.

## Artifact

DMG SHA-256: b1e5ca851620003d9d163a6f8e996a9ae2f3d85c75379f5db3a83887ec6b3015
Executable SHA-256: e751f6e2e84c2e102bd657ecec62ac916d0c8237794c4e1be79a697a7a4c2d5a
App notary submission: e8d9c126-8b8d-4230-a863-9269b72f7792 (Accepted)
DMG notary submission: dc44fbe8-f6bd-4aee-a532-63a15222d27e (Accepted)
