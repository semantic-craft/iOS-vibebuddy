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

Per-repo configuration consumed by the engineering skills (`to-tickets`, `to-spec`,
`triage`, `diagnose`, `tdd`, `improve-codebase-architecture`, `zoom-out`).

Upstream renamed `to-issues` → `to-tickets` and `to-prd` → `to-spec` in v1.1.
Those four Matt Pocock skills (plus `codebase-design`, which
`improve-codebase-architecture` references) are symlinks into
`xw-skills/mattpocock-skills` and are gitignored. The remaining skills under
`.claude/skills/` are this repo's own and are tracked. `.agents/skills` is a
bridge symlink to `.claude/skills`, so Codex/Copilot/OpenCode see the same set.

Do not run `dev-link` here — it mounts all 28 of Matt's skills and writes its
gitignore block against `.agents/skills`, which is a symlink in this repo.
Re-link per machine instead:

```bash
MP="$HOME/Projects/xw-skills/mattpocock-skills/skills/engineering"
[ -e .agents/skills ] || ln -s ../.claude/skills .agents/skills
for s in to-tickets to-spec prototype improve-codebase-architecture codebase-design; do
  ln -sfn "$MP/$s" ".claude/skills/$s"
done
```

`to-tickets`, `to-spec`, and `improve-codebase-architecture` carry upstream's
`disable-model-invocation: true`, so they are manual `/`-invoke only. The old
vendored copies had it stripped; that customization was dropped on purpose when
they moved onto the warehouse originals.

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
