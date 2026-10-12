# iOS 1.3.39 (74) — 2026-10-12

Owner authorized App Store CLI submission, including removal of read/unread and
exclusion of read-only historical failures from pending counts. This is an iOS
release; the installed Mac 1.3.47 (65) has the earlier reading-state change only.

## Changes and checks

History-only rows present in Done without changing stored failure evidence.
They age into Older after 24 hours, even if the original lifecycle recorded a
failure or wait. Live waits and live terminal failures retain existing behavior.
No claim is made that a growing collection of unresolved live failures is bounded.

- Shared Kit targeted checks passed: `TaskPresentationTests|SessionCurrencyTests`;
  includes 500 history failures plus one live question producing pending count 1.
  Evidence: `.scratch/checks/20261012T134535.953425Z-kit/results.json`.
- iPhone/Watch simulator build passed:
  `.scratch/checks/20261012T134628.415236Z-ios-build/results.json`.
- Fresh simulator `VibeBuddy No Read State QA` launched the built app in Demo.
  Native UI tooling cannot bind Simulator on this host, so no new screenshot or
  live-agent iPhone UI acceptance is claimed. Shared projection and prior Mac
  acceptance are distinct from that gap. No new physical Watch/push/audio test.
- Documentation check passed; existing review notes were updated to remove read
  acknowledgments and describe the two changes without changing contact details.

## Store delivery

Pending archive export, upload, processing, staging and submission evidence.
