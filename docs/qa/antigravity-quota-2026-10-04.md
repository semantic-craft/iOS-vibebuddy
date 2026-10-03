# Antigravity quota adapter — 2026-10-04

Implemented on `codex/antigravity-quota`, based on integration `ff225163`.
The check reports record the exact source fingerprint of the uncommitted implementation.

## Delivered

- Official `agy -p /usage --output-format json` collection through the existing bounded process supervisor (30 seconds, 1 MiB, cancellation kills its own process group). CLI owns login; no token extraction.
- Current CLI account explicitly labeled `CLI account`; the settings source text says the desktop account may differ.
- Explicit `poolKey` carries each model group's weekly and five-hour limits, percentage and reset time. Mac/iPhone detail retains all windows; Watch strips show the tightest current window of each group. Compact quota reads the tightest group/window. Passed reset windows cannot mask still-current ones.
- Missing or failed collection uses existing unavailable/stale collector behavior. A complete new Antigravity sample does not retain removed pools from an older sample.
- Shared provider mapping, Mac collector/settings, phone/Watch widget options and Watch quota deep links include Antigravity. E2E isolation still disables automatic collectors.

## Verified

Durable evidence: `~/Projects/_shared-work/iOS-vibebuddy/antigravity-quota-20261004/`.

| Check | Evidence subdirectory | Result |
| --- | --- | --- |
| Adapter, projection and account-usage checks, including real CLI fetch | `20261003T195717.034583Z-mac` | 43 tests passed; real fetch produced four windows in two model groups |
| Shared quota and roster checks | `20261003T195809.778345Z-kit` | 20 tests passed |
| Unsigned Mac app build | `20261003T195742.053675Z-mac-build` | Passed |
| iOS simulator build including embedded Watch app/widgets | `20261003T195742.053653Z-ios-build` | Passed |

Real adapter check can be repeated with `VIBEBUDDY_ANTIGRAVITY_USAGE_LIVE=1 tools/check.py mac --filter AntigravityUsageProviderTests`. It prints only window/pool counts, never account or credential contents. The opt-in test exercises `fetch()`; it is not native UI acceptance.

Red/green captured two regressions at the public quota boundary: independent model pools initially did not exist; merging a new full sample initially retained removed old pools. Source-specific fixture percentages/reset dates were taken from the read-only prototype capture.

## Remaining boundary

No app installed, launched, pushed or released by this quota slice. Native Mac display, paired iPhone/Watch propagation, accessibility/layout and notification acceptance remain with the integrated feature's E2E work. The headless daemon has no existing quota collector owner; production collection remains in the Mac application's AccountUsageCoordinator. Ticket 01 remains open for three-end acceptance.
