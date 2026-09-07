# Cross-device 1.3.5 acceptance

2026-09-07. Scope reduced by the maintainer to essential E2E checks before merging and releasing.

## Passed

- Installed and launched Developer ID signed Mac 1.3.5 (12), retaining a recoverable copy of 1.3.4. The running HTTP service publishes all four providers. Cursor has two separate 31-day pools, observed at 62% / 2% remaining.
- Installed iPhone and Watch 1.3 (14) without resetting pairing or credentials. Device inventory confirmed both versions; the acceptance iPhone connects to the paired Mac.
- A real Codex Desktop turn completed. The Mac generated its bounded completion summary. Opening that exact task on the acceptance iPhone displayed the same summary and changed the Mac's exact completionID from unread to read. A physical iPhone screenshot showed “Read — confirmed by Mac”.
- The running Mac's approval endpoint held a harmless synthetic permission probe, delivered deny, then rejected a duplicate decision with HTTP 409. No command or file modification was performed. This checks the live service receipt path; the phone action client and voice awaiting behavior are covered by the prior focused native tests.
- A physical Watch screenshot showed updated Codex 13% / Claude 49%, matching the running Mac. This demonstrates the actual relay and complication refresh.
- Prior combined checks: Kit 316 Swift Testing plus 27 XCTest; Mac 763 tests; iPhone 48 tests plus a focused 12-test rerun. Independent review passed. The main integration produces exactly the same tree as the tested implementation, so no duplicate full test run was needed.
- Mac app and DMG notarization completed successfully. Mobile 1.3 (15), differing from installed 14 only in build metadata, archived and exported for App Store Connect.

## Pending before publication

Visual confirmation of both Cursor pools on iPhone and Watch is still pending. The Watch screenshot tunnel later interrupted; its app-group copy service also rejected valid container paths. Neither tool failure is reported as an app failure. The maintainer was asked to confirm the two quota views.

This minimal E2E does not claim a new background-APNs matrix, every failure/deadline path, perceived wrist haptics, or a new microphone audio round-trip. Existing unit and protocol coverage remains in place; those broader checks were not requested for this release.

Private device captures and bounded probe outputs are retained locally under `.scratch/cross-device-coordination-audit/acceptance/release135/` and are not published with unrelated screen content.
