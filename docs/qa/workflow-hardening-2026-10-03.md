# Repository workflow hardening — 2026-10-03

## Current state

Implemented and locally verified. On 2026-10-03 the owner accepted these repository
workflow additions and explicitly authorized their local Git commit. This does not
constitute installed-app acceptance. No push, production installation or release
was performed. Base: `b92e8c71fe5cffc799bc9f4023a5c20cd8c5d7ec`
on `main`, initially clean. This work addresses source navigation, change ownership,
scoped feedback, recoverable local installation and traceable closeout.

Entry point: [development map](../agents/development.md).

## Changes

- Linked owning source directories, XcodeGen specifications, scoped checks and
  evidence rules from the existing README/agent/contributor entry points.
- Added a section index to CONTEXT and updated the handoff wrapper to the installed
  global Matt skill path. `~/.agents/skills/handoff/SKILL.md` exists on this host;
  no personal skill copies or absolute-path symlinks were added to Git.
- Split local deployment into prepare/install. Candidate copies are strictly
  verified before stopping the app; cooperating installers share a lock. Previous
  bundles survive replacement and are restored after launch/health failure.
  Runtime acceptance checks process path, single instance, port owner and health.
  Fresh shared-device coordination remains a caller attestation, not a hardware probe.
- Added scoped check reports with actual commands, exit codes, elapsed time, source
  fingerprints, not-run commands and explicit acceptance limits.
- Fixed two failures discovered during verification: Swift's exit-0/no-test filter
  now fails the check; CLI builds restore only known GUI pin pruning and preserve
  unexpected dependency changes as failures.

## Verification

Durable local evidence root:
`~/Projects/_shared-work/iOS-vibebuddy/2026-10-03-workflow-hardening/`.
This is outside checkout cleanup; it is not committed or externally published.

| Check | Result / evidence |
| --- | --- |
| Documentation links and diff whitespace | Passed; `docs/results.json` |
| Copy/signature/start/health/stop failure, lock contention, first-install failure, previous-bundle retention | Passed with disposable directories; `deployment/results.json` |
| Native signature fixture | Valid ad-hoc signature accepted, tampered bundle rejected; deployment log. Fixture never launched |
| Check-report regressions | Failure/missing tool/not-run/zero tests/source drift handled; `workflow/results.json` |
| SwiftPM pin regression | Expected pruning restored even on failed build; version change retained and failed; workflow log |
| Real Kit runner | 6 SessionCurrencyTests passed; command 16.052 s including build; `kit/results.json` |
| Real nonexistent Swift filter | Underlying Swift exited 0; runner correctly failed with verification_error; `empty-filter/results.json` |
| Real candidate preparation | Release build, embedded CLI, Production CloudKit signing, strict verification and unchanged before/after source fingerprint passed; `prepare-final.log` |
| ShellCheck | Changed shell entry points and helpers passed; `shellcheck.log` |
| Independent review | Standards: 0 findings. Spec: zero-test false pass found, fixed, and re-reviewed; 0 unresolved findings |

The first real preparation detected Package.resolved drift and exited 1 after
building/signing (`prepare.log`). The only changes were originHash and pruning of
Sparkle/MenuBarExtraAccess pins; those build-induced edits were restored. The second
preparation verified the new conditional pin restoration and exited 0.

The prepared local candidate is **1.3.42 (60)**, unchanged product version, retained
as `VibeBuddyMacApp.app` at the evidence root. It is not a published release.
Its main executable SHA-256 is
`0637694c7b77a5fe335ead4199b95a307c518f269e10bdb0924f5c36d0274f83`.
Preparation source fingerprint:
`b0bf7b6ff6f1332560cc765c4ae643a3f84871677ceef408ae8acde959acbeb7`.
`source-before.json` and `source-after.json` match. Only this QA record was added
after preparation; final check reports fingerprint the worktree including it.
The retained candidate was strictly verified again after copying to durable storage.

## Remaining acceptance boundary

### Skill entry repair — 2026-10-03

A follow-up inspection at `61d03fc3` found the three project skill entries
missing even though their tracked originals existed. Restored only the ignored
relative links under `.agents/skills/` for `verify-vibebuddy`,
`vibebuddy-history` and `vibebuddy-handoff`. The existing `.claude/skills`
link resolves through that same directory. Skill source files and the existing
uncommitted AGENTS wiring clarification were left unchanged.

All three entries resolve to their repository originals through both paths;
Git ignores the links. Wiring evidence (including original-file hashes) is in
`~/Projects/_shared-work/iOS-vibebuddy/2026-10-03-skill-entry-repair/wiring.json`.
The scoped documentation checks are recorded beside it in `docs/results.json`
and `commit-docs/results.json` (final documentation).
The next Codex turn's host-provided skill catalog listed all three project
skills at `.agents/skills/`, confirming Codex discovery. Claude discovery and
actual skill invocation were not tested. The owner accepted the repair and
authorized a local commit of the wiring clarification and this record on
2026-10-03. The links remain local and ignored; application behavior is unchanged.
No push, installation or publication is included.

### Installed application

No production app was stopped/replaced or launched, no production token was
written, and this work did not bind `:9876`. Real installed-app restart/rollback,
real-agent behavior, phone/Watch flows and Sparkle update installation remain
unverified by this change. Installing the candidate needs authorization covering
replacement and a fresh peer/device check; the completed local checks do not
establish those runtime outcomes. Existing app compiler warnings remain unchanged.
