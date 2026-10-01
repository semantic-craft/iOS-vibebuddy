# October integration acceptance

Implementation baseline: `aec5edda`; initial implementation candidate: `33139836`.
Work used the existing `codex/language-restart` worktree. No files in the primary
checkout were included. No production installation, release or push was performed.

## Results by slice

| Tickets | Result and evidence |
| --- | --- |
| 01 / 03 | Current Codex producer certification, bounded event delivery, reconnect recovery and read-only retry: [evidence](acceptance-codex-reliability.md). |
| 04 / 05 / 06 | Paged history, official goal and background-terminal read views: [evidence](acceptance-codex-reads.md). |
| 02 / 07 / 09 | Cursor hook failures, configured MCP and persistent observation: [evidence](acceptance-cursor-local.md). |
| 08 | Cloud run stream, scoped reconnect cursor and authoritative polling fallback: [evidence](acceptance-cursor-cloud.md). |

## Shared checks

- Mac package: 1,173 tests passed (154 suites) before the final review fixes.
  After those fixes, 39 focused tests in six suites passed, including both
  reproduced reconnect/order regressions.
- Shared Kit: 499 tests passed (97 suites).
- Final Mac app Debug build passed with signing disabled.
- Persistent-discovery diagnostics use an optional snapshot field. No new value
  is emitted in the existing `ObservationSource` wire enum, so older clients can
  continue decoding snapshots.

## Review

Independent Standards review of the initial candidate found one ADR mismatch:
the Cursor hook failure contract needed to reflect the implemented exit behavior.
An independent Spec check of ticket 08 found no actionable deviation; its 36
focused tests also passed. Real CLI checks did not reproduce a block from the former empty-output exit 0;
the documented change must not claim otherwise.

Independent Spec review identified reconnect isolation and stale completion
ordering issues in the initial Codex candidate. Both were fixed and the
coordinator checked the resulting diff. Their final fixes and regression
checks are recorded in the Codex reliability evidence.

## Acceptance boundaries

The evidence distinguishes live local CLI/app-server behavior from deterministic
protocol fixtures. Cloud account/SSE behavior and physical phone/APNs delivery
were not validated. No claim of improved production latency follows from the
local stream benchmark or bounded-buffer test. This work is not yet installed
or user-accepted in the production app.

All isolated daemon runs were stopped by their own recorded PIDs; evidence
survived cleanup. Real Cursor MCP probes restored the prior user configuration.

Subsequent user-authorized [live phone/cloud acceptance](acceptance-live-phone-cloud.md)
verified actual APNs acceptance for real Cursor task completion and reminders.
Visible phone delivery still requires the user’s confirmation; the cloud account
check remains pending its separate API key.
