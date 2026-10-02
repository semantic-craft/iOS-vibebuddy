# Grok monitoring acceptance — 2026-10-02

## Scope and result

GROK-02 and GROK-03 are implemented on Mac. Tickets were published in
`2548ebe6`; implementation is `0e4f45f9`, with review fixes in `c14d055e`.
The parent GROK-01 remains unchanged. Completed child tickets and their index
rows are removed according to the local tracker convention.

The Mac has a dedicated monitoring toggle that installs Grok hooks, reports
configuration failures, and retries the last requested state. Account quota
remains a separate setting. Live registry entries appear as discovery cards
until real hooks report session activity. Discovery does not fabricate task
progress or notifications. Disabling monitoring persists across restart.

The shared snapshot carries optional `grokMonitoring` data. iOS still renders
ordinary connected sessions through its existing path; it does not yet render
the new discovery or setup-status cards. No iOS UI acceptance is claimed.

## Verification

- `swift build --package-path VibeBuddyMac`: passed.
- XcodeGen followed by Debug macOS `xcodebuild`, signing disabled: passed.
- GrokMonitoringTests, GrokSessionStoreTests, GrokACPTests and HookInstallerTests:
  68 tests across 5 suites passed on the final implementation.
- VibeBuddyKit: 501 tests across 98 suites passed in the current workspace.
- Simplified Chinese strings passed `plutil -lint`.

An isolated app (`com.vibebuddy.e2e.grok-onboarding`, port 18863) was exercised
through Computer Use. Its settings and support directory were disposable.
The running user's Grok registry was read and copied for discovery; production
Grok configuration was not edited.

Verified in the native UI: discovery card and Grok sidebar entry; navigation
from the card and quota settings to agent integration; separate quota and
monitoring toggles; persistent off state across restart; reload guidance; and
an actual state-file write failure followed by successful in-place retry.
Retry retained the user's requested on state after the failed save.

A disposable `grok agent --no-leader stdio` session performed initialize and
session/new, with no model prompt. Its native SessionStart hook reached the
isolated app and changed the connected count. The existing user's Grok session
was not reloaded. Same-ID discovery-to-hook deduplication was separately
verified by regression test. HTTP and WebSocket snapshot payloads matched;
discovery-only state contained no fabricated AgentSession.

Session-local logs and probes are under `.scratch/grok-build-onboarding/`.
The isolated app was stopped and its disposable state/home removed after
acceptance, including temporary authentication material.

## Full-suite limitations

The full Mac suite was attempted but was not green and did not complete.
CursorQuotaRelayTests and ProviderQuotaProjectionTests produced eight issues
across two tests; an isolated rerun reproduced those eight issues. The affected
quota implementation and test files are unchanged by this work. A clean
baseline run was not performed, so preexistence is not established by execution.

The full parallel run also encountered a Grok ACP authentication timeout and
nil-unwrap crash. Subsequent focused runs including GrokACPTests passed. This
does not establish that the full-suite failure is resolved.

## Standards review

An independent reviewer identified one configuration-validation issue:
managed commands alone could report configured when required executable hooks
were missing. Exact command and executable checks now cover that case, with a
regression test. Follow-up review reported no remaining standards findings.

## Spec review

An independent reviewer identified one retry issue: failure to save state could
hide the error and lose the requested toggle state. In-memory operation error
and requested-state retention now preserve both. Native UI fault injection and
follow-up review confirmed the fix; no remaining spec findings were reported.

## Delivery boundary

Changes are committed locally. No push, packaged release, production-token
change, production port binding, or replacement of the installed app was done.
Other work already present in this checkout was preserved; build/test results
describe that workspace, not a clean checkout of the cited commits.
