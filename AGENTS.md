# AGENTS.md

Agent-facing configuration for the iOS-vibebuddy repo.

## Scope and inherited rules

Apply the active global instructions, then ancestor-directory rules, then this
file and any more specific instructions for the files being changed. Project
rules specialize inherited defaults; they do not override higher-priority
session instructions or grant permission for external or destructive actions.

For this checkout, `~/Projects/AGENTS.md` supplies cross-machine sync and repo
authority rules. Its GitHub issue-tracker default is replaced by the local
Markdown convention below. Consult its sync runbook and live authority state
when cross-machine work is requested; routine local work does not trigger sync.

## Project delivery boundaries

Use the global rules for autonomy, clarification, approval, preserving existing
work, and completion. This project adds these delivery boundaries:

- Commit, push, cross-machine sync, installation or replacement of the user's
  running app, deployment, and release require authorization covering that
  action. Authorization already given remains valid within its scope;
  reporting separate states does not create separate approval gates.
- Using configured authentication for an authorized operation is part of that
  operation. Reading secret values for context or changing credentials is not
  implied.

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

Skills come from `dev-link` (Matt Pocock groups + `design-ui`), never from
anything tracked in this repo. `.agents/skills/<name>` are absolute symlinks
into the `xw-skills` warehouse, and `.claude/skills/<name>` are relative
symlinks pointing at those. Both directories are gitignored/excluded and
machine-local. When updating the project's linked skills after warehouse
changes, re-run `dev-link` and reopen the session as required by the global
skill-wiring rules. Ordinary tasks do not require refreshing skills. This repo
owns no skills of its own.

Use a skill when explicitly requested or when its stated trigger fits the task.
Apply its relevant branch within the user's scope and these project conventions.
The skill inventory does not make every workflow mandatory: routine work does
not automatically require a PRD, ticket, multiple models, subagents, test-first
development, or a full test suite. Preserve explicitly requested model routing
and workflows; a skill does not independently authorize external actions.

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

## Domain docs

**Single-context** layout — one `CONTEXT.md` + `docs/adr/` at the repo root.
Before exploring or changing domain behavior, terminology, or architecture,
follow `docs/agents/domain.md`, read `CONTEXT.md` and the relevant ADRs. Read
unrelated ADRs only if the task reaches their subject. Flag conflicts with an
existing ADR before implementing a conflicting decision. Documentation or
mechanical edits that do not affect domain meaning need no domain exploration.
