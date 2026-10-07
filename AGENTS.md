# AGENTS.md

Agent-facing configuration for the iOS-vibebuddy repo. Global rules apply first; this file adds project facts.

## Delivery boundaries

The task goal authorizes the delivery steps it includes: installation, the production port `:9876`, login-token setup under `~/Library/Application Support/vibebuddy/`, release, or cross-machine sync, without separate per-step approval. Check shared-app ownership before replacing `/Applications/VibeBuddyMacApp.app`: it is one copy shared by every session on this Mac, and replacing it kills any real-device acceptance another session is running — check for a peer run first (`docs/sparkle-setup.md`, § The installed app is shared). If a peer is using that copy, defer replacement, continue independent work, and report the remaining installation step. Configured credentials may be used for an authorized operation; reading secrets for context is not implied.

Before changing app or daemon behavior, running app/daemon acceptance, or claiming verification complete, read **Verification** in [CODING_STANDARDS.md](CODING_STANDARDS.md). Apply its affected-flow end-to-end standard, isolated runtime boundary, and explicit treatment of unavailable real-device or installed-app acceptance.

## Skills

Repository-owned skills live in `docs/agents/skills/` and are tracked here: `verify-vibebuddy` (isolated runtime acceptance), `vibebuddy-history` (resuming from handoff notes and `vibebuddy-mcp facts`), `vibebuddy-handoff` (source-identified handoff notes). For these three skills, `.agents/skills/<name>` is an untracked relative link to `../../docs/agents/skills/<name>`; `.claude/skills/` points to that face and also stays untracked.

## Task references

| Work | Reference |
| --- | --- |
| Finding owning source, choosing scoped checks, or recording delivery evidence | `docs/agents/development.md`; executable profiles: `tools/check.py --list` |
| Creating, reading, or updating tickets and PRDs — tracked Markdown under `docs/planning/backlog/<feature>/` with an index row, not GitHub Issues and not `.scratch/`; a skill's "publish to the issue tracker" means writing and committing that file | `docs/agents/issue-tracker.md` |
| Assigning or changing triage state (`needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix` as a `Status:` line) | `docs/agents/triage-labels.md` |
| Changing domain behavior, terminology, or architecture (single-context layout: `GLOSSARY.md` + `docs/adr/`) | `docs/agents/domain.md`, `GLOSSARY.md`, and the relevant ADRs; flag a conflict with an existing ADR before implementing against it |
| Resuming earlier work ("上次", "昨天", "继续") | `docs/agents/skills/vibebuddy-history/SKILL.md`: newest handoff note first, then `vibebuddy-mcp facts` for its source session to check drift, then `show` for that session's transcript only where the note leaves gaps. There is no archive or search of past conversations. Optional `status --exclude-session` reports other sessions in this checkout; report them and let the user decide. The tools are read-only |
| Writing a source-identified handoff | `docs/agents/skills/vibebuddy-handoff/SKILL.md`: run `vibebuddy-mcp facts` for the writer's own session key first and place its block at the top |
| Opening or merging a pull request to `main` — review with an independent AGY CLI Gemini session first, post the verdict on the PR; no bot review, no required checks | `docs/agents/pr-review.md` |
| Planning the next cycle or changing macOS distribution, sandboxing, or agent integration | `docs/agents/mac-app-store.md`: the owner's designated next direction, not authorization to start it |
