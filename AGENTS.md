# AGENTS.md

Agent-facing configuration for the iOS-vibebuddy repo.

## Scope and delivery

Apply the active global and ancestor rules, then the rules for the affected path.
Cross-machine work uses `~/Projects/AGENTS.md` when present; other clones have no
fleet. Routine work does not trigger synchronization.

Commit, push, cross-machine sync, installing or replacing the running app,
deployment, and release need authorization covering that action. Existing
authorization remains valid within its scope. Configured authentication may be
used for an authorized operation; reading secrets for context is not implied.

## Verification strategy

This is a personal-use project. For changes to app or daemon behavior, default
to real end-to-end acceptance: build and run the actual affected app/daemon,
exercise the affected flow with real Claude Code or Codex Desktop/CLI data
within the authorized scope, and verify the relevant snapshot, UI, notification,
recovery, or installation behavior. Check only the behaviors affected by the
change; installation acceptance is subject to the delivery boundaries above.
Use an isolated build or instance when it can verify the behavior without
replacing the running app. If real-device or installed-app acceptance requires
an unavailable device or additional authorization, finish the implementation
and available checks, then report that specific acceptance gap. Those checks
do not prove the blocked acceptance.

For documentation-only changes, inspect the diff, referenced paths, and rule
consistency; no app build or launch is needed. For build, configuration, or
tooling changes, run the affected command and check its result, adding runtime
acceptance when runtime behavior is affected. After sufficient checks pass,
expand validation only for new changes, failures, or unresolved risks.

Keep only a small number of fast automated tests for critical pure logic or a
previously reproduced regression. Test-first development, coverage targets, and
one-test-per-edge-case matrices are not required. Preserve existing useful
tests, but do not let low-value test expansion displace end-to-end validation.

## Agent skills

Project `.agents/skills/` entries link to originals in `xw-skills`;
`.claude/skills/` points to those local entries. Both are excluded from Git.
Edit the original, preserve valid links, and follow global wiring rules only
when links or names change.

This repo owns one skill, tracked in Git because it encodes these routes,
ports and QA conventions: `docs/agents/skills/verify-vibebuddy/` drives an
isolated `vibebuddyd` and the iPhone Demo the way a user does. Edit it here,
not in `xw-skills`. Link it into the machine-local skill face so every agent
can discover it:

    ln -s ../../docs/agents/skills/verify-vibebuddy .agents/skills/verify-vibebuddy

The link is untracked like the rest of `.agents/`; the skill itself is not.

Use skills for their actual task triggers. Ordinary work does not require a PRD,
ticket, multiple models, test-first development, or a full suite. Explicitly
requested workflows and model choices remain binding within the user's scope.

## Issue tracker

Issues and PRDs live as **local markdown** under `.scratch/<feature>/` in this repo
(not GitHub Issues). When creating, reading, or updating tickets or PRDs, follow
`docs/agents/issue-tracker.md`. A skill's instruction to publish to the issue
tracker means writing the local Markdown file, not publishing remotely.

### Triage labels

Five canonical triage roles use their **default strings** (`needs-triage`,
`needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`), recorded as a
`Status:` line in each issue file. When assigning or changing triage state, follow
`docs/agents/triage-labels.md`.

## Next-work discovery

When planning the next development cycle or changing macOS distribution,
sandboxing, or agent integration, read `docs/agents/mac-app-store.md` and its
local checklist. The owner has designated the Mac App Store edition as an
important next direction while retaining direct distribution. This pointer
does not authorize starting that work or overriding the user's current task.

## Domain docs

**Single-context** layout — one `CONTEXT.md` + `docs/adr/` at the repo root.
Before exploring or changing domain behavior, terminology, or architecture,
follow `docs/agents/domain.md`, read `CONTEXT.md` and the relevant ADRs. Read
unrelated ADRs only if the task reaches their subject. Flag conflicts with an
existing ADR before implementing a conflicting decision. Documentation or
mechanical edits that do not affect domain meaning need no domain exploration.
