# Pull request review with the local Grok Build CLI

`main` is PR-only (ruleset "Protect default branch": no deletion, no force push, changes through a pull request). No bot reviews PRs and no status check is required; the review is run locally with Grok Build before the PR is opened, or before it is merged when the PR already exists. The reviewer of record is Grok; the agent that wrote the change triages the findings.

## Run

```
S=<scratchpad>
git diff origin/main...HEAD > $S/pr.diff
~/.grok/bin/grok --prompt-file $S/prompt.md --cwd <worktree> --permission-mode plan \
    --disable-web-search --max-turns 60 --output-format plain > $S/review.md 2> $S/review.err
```

- `--permission-mode plan` is read-only. Run it in the background; a round takes 10–15 minutes.
- The prompt names the diff file and the changed files, gives the context a reviewer would not infer from the diff (the bug, the measurement, the design intent), points at the callers to read, and asks for `file:line`, severity (blocker / should-fix / nit), a concrete failure scenario, the fix, and a verdict: MERGE / MERGE WITH FIXES / DO NOT MERGE.
- For a re-review, hand it the full diff plus a diff of the fix commit, list the earlier findings with what was fixed or deliberately left, and ask for FIXED / NOT FIXED per item plus regressions.

## After the round

Fix the valid findings, state the deliberate non-fixes with the reason, push, and post the verdict and the triage as one PR comment (`gh pr comment`). Grok is strong on SwiftUI identity and state pitfalls and reads real line numbers; check its "spec" findings against the design intent before acting on them. The merge itself is the owner's.
