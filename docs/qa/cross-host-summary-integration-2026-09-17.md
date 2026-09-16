# Cross-host integration and completion summary acceptance

## Scope

Integrate cross-host PR #214, which shares task dispatch orchestration and encapsulates completion evidence. The old uncommitted remote working tree remains intact. Its TaskDispatcher matches the PR; its documentation changes are already on main.

The requested reminder behavior is native completion before summarizing and notifying. No cooldown, frequency preference, or reminder interval was changed. In addition to the existing speech checks, completion notification generation now waits for verified native settlement and rechecks after generation. Unverified expiry cancels the notice instead of emitting a plain completion. Cursor uses this notice path too.

## Automated verification

- 213 Swift Testing tests in 32 suites and 11 XCTest cases passed. The selection covers dispatch, continuation, completion evidence, recap, history reading, Codex and Cursor monitors, hook parsing and presentation.
- Regression checks for Claude Code and Cursor verify zero notification generator calls before native settlement, then cancellation if continuation evidence appears during generation.
- A hook-only unverified ending expires silently.
- Real local Claude, Codex and Cursor source replay remains enabled in the test run.
- Two fresh Codex tasks ran through a private app-server and the integrated daemon's HTTP dispatch route. All 15 checks passed: launch, native completion, exact final body and identity, continuation lineage, no implicit read acknowledgement, source coverage and isolated cleanup. Temporary authentication copies and HOME were removed.
- Before replacement, the installed App's authenticated presentation route returned `generated: true` for real Codex and Claude Code results using its configured summary provider. This establishes live provider operation, not final-version installed acceptance.

Raw private task bodies and credentials are not committed. Bounded evidence is retained in the local verification directory.

## Installed build 40 acceptance

- Both authorized hosts run Developer ID signed 1.3.23 build 40, with identical executable SHA256 `eaaddc524125e1f2878fcbb8c0a2fe29303720cadb79a8fc417b7904f674c639`. Strict signature checks pass, health is OK, and one App instance owns the production port on each host. Previous App bundles are backed up.
- Fresh tasks on the primary host exercised real HTTP dispatch for Codex, Claude Code and Cursor. Each moved from working to done, returned its exact requested result, generated a summary through the configured provider, included the conversation name, and reached notification state `summary`.
- Native evidence was checked: Codex `task_complete`; Claude `end_turn` and `stop_hook_summary`; Cursor's hosted ACP completion. The Codex task remained working during its approximately 98-second run.
- The installed native dashboard displayed the Cursor conversation name and generated summary.
- On the secondary host, a real Codex result generated a named summary. A fresh Claude Code task returned native `authentication_failed` before producing a result. Its end-to-end summary check remains blocked on restoring that host's Claude login.
- The secondary checkout's existing tracked diff hash and untracked work were preserved.

Human listening and reproduction of the original drawing task's visible spinner remain separate from these checks. No reminder-frequency setting was changed.
