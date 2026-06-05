# AGENTS.md

Agent-facing configuration for the iOS-vibebuddy repo.

## Agent skills

Per-repo configuration consumed by the engineering skills (`to-issues`, `to-prd`,
`triage`, `diagnose`, `tdd`, `improve-codebase-architecture`, `zoom-out`).

### Issue tracker

Issues and PRDs live as **local markdown** under `.scratch/<feature>/` in this repo
(not GitHub Issues). See `docs/agents/issue-tracker.md`.

### Triage labels

Five canonical triage roles use their **default strings** (`needs-triage`,
`needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`), recorded as a
`Status:` line in each issue file. See `docs/agents/triage-labels.md`.

### Domain docs

**Single-context** layout — one `CONTEXT.md` + `docs/adr/` at the repo root.
See `docs/agents/domain.md`.
