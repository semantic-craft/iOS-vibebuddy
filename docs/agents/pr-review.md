# Pull request review with independent Grok Build

`main` is PR-only (ruleset "Protect default branch": no deletion, no force push, changes through a pull request). No bot reviews PRs and no status check is required. Since 2026-10-01 the owner's reviewer of record is an independent Grok Build session (`grok-4.7-build-fast`, `xhigh`), run by the agent that wrote the change before the PR is merged. Claude Code / Opus is no longer required for this project. The author triages the findings.

## Run

Start a fresh read-only Grok Build session using the local CLI (`grok --model grok-4.7-build-fast --reasoning-effort xhigh`); check `grok --help` for current headless and permission flags. Give it:

- the branch and the range to review (`git diff origin/main...HEAD`);
- the ticket or ADR that defines the intended behaviour, and the context a reviewer would not infer from the diff (the bug, the measurement, the design intent);
- the callers and neighbouring surfaces to read, not just the diff;
- the specific risks to look hard for;
- the output: each finding as `file:line`, severity (blocker / should-fix / nit), a concrete failure scenario and the fix, then a verdict: MERGE / MERGE WITH FIXES / DO NOT MERGE.

The reviewer may run `swift test`; it does not edit, commit, push or comment on GitHub. For a re-review, give it the fix commit plus the earlier findings and ask for FIXED / NOT FIXED per item plus regressions.

## After the round

Fix the valid findings, state the deliberate non-fixes with the reason, push, and post the verdict and the triage as one PR comment (`gh pr comment`). Check "spec" findings against the design intent before acting on them. Merge only when the owner has authorized it; existing authorization in the task remains valid.
