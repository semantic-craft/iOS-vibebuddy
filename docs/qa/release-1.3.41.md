# macOS 1.3.41 / iOS 1.3.33 release verification

2026-10-02 (Asia/Shanghai). Mac build 59; iPhone / Watch build 68.

The release inherits `3b6f481f` (PR #338), including the language-restart and
Codex/Cursor integration from PR #337 and the previously merged Cloudflare work.
New implementation range: `3b6f481f..62b5fbd5`; release metadata: `a9601b25`; review fixes: `41a72c48`.
Old dirty files in the primary checkout were compared against current main and
left intact; they must not overwrite later fixes or resurrect completed tickets.

## Scoped acceptance

See `docs/planning/backlog/ios-companion-parity/acceptance.md` for the initial
501 Kit / 1,182 Mac / 177 iOS tests and the separately exercised network gates.
The final follow-up ran only this batch's affected flows:

- All four MiniMax styles returned real speech and reached the native iOS player.
- Final audio/network tests: 12 passed. Includes failed-request audio routing,
  denied voice takeover, pause/resume, completion and real history source identity.
- Native UI tests: 2 passed, exercising Chinese settings with default and maximum
  accessibility text sizes, key draft cancellation and keyboard dismissal, task
  unavailability and fallback to real local Codex history.
- Real API first audio was 0.851–1.443 seconds in the four-style run (one sample
  per style). Duplicate audio-session operations were removed; no claim of
  statistically improved network latency or frame performance.
- API key was entered via a native secure prompt with Paste, used transiently,
  and deleted. Isolated daemon and simulator were stopped after acceptance.

Physical ear/headphone/VoiceOver and populated native goal/terminal acceptance
remain unverified. No full-app or physical Watch acceptance is inferred.

## Release artifacts

- macOS Release build, Developer ID signatures, Production iCloud cues, app and
  DMG notarization/stapling, Gatekeeper assessment and Sparkle appcast succeeded.
  Final app notary ID: `3948a500-a743-453c-9dda-ccb2f49d7d43`.
  Final DMG notary ID: `04e1f352-1ba6-44ef-9b28-6419c2b8ae47`.
  The initial artifacts were superseded after review and were never published.
- iOS archive/export succeeded. All five app/extension products have version
  1.3.33 (68) and pass strict signature verification. Distribution signing,
  production APNs and Time Sensitive entitlements were verified.
- Initial iOS export hit the documented rsync PATH conflict. Retrying only
  export with `/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin` succeeded.
  The full archive script needs Homebrew Bash explicitly with that PATH (system
  Bash 3 treats its empty authentication array as unbound under `set -u`).

Evidence remains local in `.scratch/release-1.3.41/` and `.scratch/ios-parity-e2e/`.

## Independent Grok Build review

`grok-4.7-build-fast`, `xhigh`, independent session
`01a0f977-8397-7523-b8f3-27775fc9cd87` completed a full review and a fix re-review.
Initial verdict MERGE WITH FIXES; final verdict **MERGE**, all seven findings FIXED.

- Resume does not release pause or advance the queue until the player accepts it.
- Expired/non-advancing terminal cursors are cleared; loaded pages stay visible.
- Goal and terminal failures recover independently.
- Transient Codex history fallback offers in-page retry, while old Macs keep fallback.
- The server detects repeated native cursors before opaque token wrapping.
- A missing explicit voice override stays missing, so language changes recompute defaults.
- Key deletion uses a deletion-specific success message.

The server history/terminal cursor regression failed before the fix and passed
with it (3 focused tests). Final phone audio/network regression checks passed
12/12; the native history UI test also exercised the new fallback retry.
The default/max-size settings test switches language through actual controls;
launch argument overrides cannot test a mutable preference because they shadow
saved values. Selected picker text is asserted through its accessibility child.

Build 67 uploaded before review fixes and is superseded by build 68; it was not
submitted for App Store review. App Store webpage login is still required for
store metadata/review submission; successful package upload is not store approval.
