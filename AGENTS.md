# AGENTS.md

Agent-facing configuration for the iOS-vibebuddy repo. Global rules and `~/Projects/AGENTS.md` apply first; this file adds project facts.

## Delivery boundaries

Installing or replacing the running app, binding `:9876`, writing the login token under `~/Library/Application Support/vibebuddy/`, release, and cross-machine sync need authorization covering that action. Authorization alone is not enough for `/Applications/VibeBuddyMacApp.app`: it is one copy shared by every session on this Mac, and replacing it kills any real-device acceptance another session is running — check for a peer run first (`docs/sparkle-setup.md`, § The installed app is shared). Existing authorization stays valid within its scope. Configured credentials may be used for an authorized operation; reading secrets for context is not implied.

## Verification

Personal-use project. For app or daemon behavior changes, accept end to end: build and run the affected app or daemon, exercise the affected flow with real Claude Code or Codex data within the authorized scope, and check the snapshot, UI, notification, recovery, or installation behavior the change touches. Check only affected behaviors.

Run without asking: `swift build` / `swift test` in this checkout, XcodeGen and simulator builds, and an isolated `vibebuddyd` on a non-9876 port with a disposable HOME (`verify-vibebuddy` owns that recipe). Never launch a second production menu-bar instance.

If real-device or installed-app acceptance needs an unavailable device or extra authorization, finish the implementation and the available checks, then report that specific gap; the other checks do not prove it.

Keep a small number of fast tests for critical pure logic or a reproduced regression. No coverage targets, test-first mandates, or per-edge-case matrices; do not let test expansion displace end-to-end validation.

## Skills

`.agents/skills/` links to originals in `xw-skills`; `.claude/skills/` points at those links. Both are untracked. Edit originals and keep valid links.

Repository-owned skills live in `docs/agents/skills/` and are tracked here: `verify-vibebuddy` (isolated runtime acceptance), `vibebuddy-history` (resuming from handoff notes and `vibebuddy-mcp facts`), `vibebuddy-handoff` (source-identified handoff notes). Link them into the local face when needed:

    ln -s ../../docs/agents/skills/vibebuddy-history .agents/skills/vibebuddy-history

## Task references

| Work | Reference |
| --- | --- |
| Creating, reading, or updating tickets and PRDs — tracked Markdown under `docs/planning/backlog/<feature>/` with an index row, not GitHub Issues and not `.scratch/`; a skill's "publish to the issue tracker" means writing and committing that file | `docs/agents/issue-tracker.md` |
| Assigning or changing triage state (`needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix` as a `Status:` line) | `docs/agents/triage-labels.md` |
| Changing domain behavior, terminology, or architecture (single-context layout: `CONTEXT.md` + `docs/adr/`) | `docs/agents/domain.md`, `CONTEXT.md`, and the relevant ADRs; flag a conflict with an existing ADR before implementing against it |
| Resuming earlier work ("上次", "昨天", "继续") | `docs/agents/skills/vibebuddy-history/SKILL.md`: newest handoff note first, then `vibebuddy-mcp facts` for its source session to check drift, then `show` for that session's transcript only where the note leaves gaps. There is no archive or search of past conversations. Optional `status --exclude-session` reports other sessions in this checkout; report them and let the user decide. The tools are read-only |
| Writing a source-identified handoff | `docs/agents/skills/vibebuddy-handoff/SKILL.md`: run `vibebuddy-mcp facts` for the writer's own session key first and place its block at the top |
| Opening or merging a pull request to `main` — review with an independent Opus subagent first, post the verdict on the PR; no bot review, no required checks | `docs/agents/pr-review.md` |
| Planning the next cycle or changing macOS distribution, sandboxing, or agent integration | `docs/agents/mac-app-store.md`: the owner's designated next direction, not authorization to start it |
