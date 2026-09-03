# AGENTS.md

Agent-facing configuration for the iOS-vibebuddy repo.

## Verification strategy

This is a personal-use project. Default to real end-to-end acceptance: build and
run the actual Mac app/daemon, exercise it with real Claude Code or Codex
Desktop/CLI data, and verify the resulting snapshot, UI, notification, recovery,
and installation behavior as applicable.

Keep only a small number of fast automated tests for critical pure logic or a
previously reproduced regression. Test-first development, coverage targets, and
one-test-per-edge-case matrices are not required. Preserve existing useful
tests, but do not let low-value test expansion displace end-to-end validation.

## Agent skills

Skills come from `dev-link` (Matt Pocock groups + `design-ui`), never from
anything tracked in this repo. `.agents/skills/<name>` are absolute symlinks
into the `xw-skills` warehouse, and `.claude/skills/<name>` are relative
symlinks pointing at those. Both directories are gitignored/excluded and
machine-local. Re-run `dev-link` after pulling warehouse changes; this repo
owns no skills of its own.

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
