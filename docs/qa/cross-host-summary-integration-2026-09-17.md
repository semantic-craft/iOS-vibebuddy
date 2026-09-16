# Cross-host integration and completion summary acceptance

## Scope

Integrate Cross-host PR #214, which shares task dispatch orchestration and encapsulates completion evidence. The old uncommitted remote working tree remains intact. Its TaskDispatcher matches the PR; its documentation changes are already on main.

The requested reminder behavior is native completion before summarizing and notifying. No cooldown, frequency preference, or reminder interval was changed. In addition to the existing speech checks, completion notification generation now waits for verified native settlement and rechecks after generation. Unverified expiry cancels the notice instead of emitting a plain completion. Cursor uses this notice path too.

## Automated verification

- 213 Swift Testing tests in 32 suites and 11 XCTest cases passed. The selection covers dispatch, continuation, completion evidence, recap, history reading, Codex and Cursor monitors, hook parsing and presentation.
- Regression checks for Claude Code and Cursor verify zero notification generator calls before native settlement, then cancellation if continuation evidence appears during generation.
- A hook-only unverified ending expires silently.
- Real local Claude, Codex and Cursor source replay remains enabled in the test run.
- Two fresh Codex tasks ran through a private app-server and the integrated daemon's HTTP dispatch route. All 15 checks passed: launch, native completion, exact final body and identity, continuation lineage, no implicit read acknowledgement, source coverage and isolated cleanup. Temporary authentication copies and HOME were removed.
- Before replacement, the installed App's authenticated presentation route returned `generated: true` for real Codex and Claude Code results using its configured summary provider. This establishes live provider operation, not final-version installed acceptance.

Raw private task bodies and credentials are not committed. Bounded evidence is retained in the local verification directory.

Installed-version checks and human listening are separate from the above automated checks.
