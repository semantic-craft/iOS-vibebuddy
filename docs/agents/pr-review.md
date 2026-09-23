# Pull request review with an independent Opus subagent

`main` is PR-only (ruleset "Protect default branch": no deletion, no force push, changes through a pull request). No bot reviews PRs and no status check is required. Since 2026-09-23 the owner's reviewer of record is an independent Claude Opus subagent (Opus 5.5, medium depth), run by the agent that wrote the change before the PR is merged; Grok Build is no longer used for review. The author triages the findings.

## Run

Spawn a fresh subagent (Claude Code `Agent` tool, `code-reviewer` type, model `opus`, in the background) with a read-only brief:

- the branch and the range to review (`git diff origin/main...HEAD`);
- the ticket or ADR that defines the intended behaviour, and the context a reviewer would not infer from the diff (the bug, the measurement, the design intent);
- the callers and neighbouring surfaces to read, not just the diff;
- the specific risks to look hard for;
- the output: each finding as `file:line`, severity (blocker / should-fix / nit), a concrete failure scenario and the fix, then a verdict: MERGE / MERGE WITH FIXES / DO NOT MERGE.

The reviewer may run `swift test`; it does not edit, commit, push or comment on GitHub. For a re-review, give it the fix commit plus the earlier findings and ask for FIXED / NOT FIXED per item plus regressions.

## After the round

Fix the valid findings, state the deliberate non-fixes with the reason, push, and post the verdict and the triage as one PR comment (`gh pr comment`). Check "spec" findings against the design intent before acting on them. The merge itself is the owner's.
