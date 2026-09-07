# Cross-device 1.3.5 acceptance

2026-09-07. Scope reduced by the maintainer to essential E2E checks before merging and releasing.

## Passed

- Installed and launched Developer ID signed Mac 1.3.5 (12), retaining a recoverable copy of 1.3.4. The running HTTP service publishes all four providers. Cursor has two separate 31-day pools, observed at 62% / 2% remaining.
- Installed iPhone and Watch 1.3 (14) without resetting pairing or credentials. Device inventory confirmed both versions; the acceptance iPhone connects to the paired Mac.
- A real Codex Desktop turn completed. The Mac generated its bounded completion summary. Opening that exact task on the acceptance iPhone displayed the same summary and changed the Mac's exact completionID from unread to read. A physical iPhone screenshot showed “Read — confirmed by Mac”.
- The running Mac's approval endpoint held a harmless synthetic permission probe, delivered deny, then rejected a duplicate decision with HTTP 409. No command or file modification was performed. This checks the live service receipt path; the phone action client and voice awaiting behavior are covered by the prior focused native tests.
- A physical Watch screenshot showed updated Codex 13% / Claude 49%, matching the running Mac. This demonstrates the actual relay and complication refresh.
- Prior combined checks: Kit 316 Swift Testing plus 27 XCTest; Mac 763 tests; iPhone 48 tests plus a focused 12-test rerun. Independent review passed. The main integration produces exactly the same tree as the tested implementation, so no duplicate full test run was needed.
- Mac app and DMG notarization completed successfully. The final mobile 1.3 (15), including the Watch layout correction below, archived, exported and uploaded successfully.

## Final essential E2E

The actual Watch received-application-context cache was decoded locally and contained the exact Cursor Models 62% and Other Models 2% pools, with the same observation/reset times as the Mac. This verifies the full Mac → physical iPhone → physical Watch path, not a simulator fixture.

The real Watch quota screen exposed empty weekly/short placeholder rows ahead of the actual Cursor pools. Those absent windows are now omitted. Independent review and the final signed mobile build passed. iPhone and Watch build 15 were installed; a physical Watch screenshot at 18:09 displayed both named 31-day pools, 62% and 2%, together on the first screen. This closes the final necessary release check without requiring an additional manual user confirmation.

Phone quota rendering was covered by the focused native checks; the separate phone quota sheet was not captured during this minimal E2E. The phone completion-detail and read-confirmation sheet was captured on the physical device.

This minimal E2E does not claim a new background-APNs matrix, every failure/deadline path, perceived wrist haptics, or a new microphone audio round-trip. Existing unit and protocol coverage remains in place; those broader checks were not requested for this release.

Private device captures and bounded probe outputs are retained locally under `.scratch/cross-device-coordination-audit/acceptance/release135/` and are not published with unrelated screen content.

## Release receipt

- PR #124 merged as `9e0a324e77cddd5ca488772c500a952b5cb65191`; its tree matches the tested release commit.
- Mac v1.3.5 is public on GitHub. Installed 1.3.5 (12) passed `spctl` as Notarized Developer ID. Live Sparkle feed advertises build 12 and its published DMG; previous 1.3.4 URLs remain valid.
- DMG SHA-256: `25f5e50db367b6e5911a276b61053bac2405a2ad2da5492b03600e50176275fe`, matching the GitHub asset digest.
- At 18:22 Asia/Shanghai, App Store Connect accepted iOS/Watch 1.3 (15): Waiting for Review, submission `a2ba9729-ce00-456a-9c81-059b1d8e4adb`, build `a9efed21-a27f-4e0a-987b-d6ce2aff67b4`. Automatic release after approval remains selected. This is submission, not App Store approval or public availability.
