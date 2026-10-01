# Settings language restart and agent status — 2026-10-01

## Change

- General → Language now offers **Restart VibeBuddy**. The helper waits for normal process exit and the single-instance lock release before reopening the exact app bundle.
- Agent integration shows observation status separately from Hook configuration. A missing Hook no longer implies a missing integration. Receiving activity does not claim remote-control support.
- Preserve the previously uncommitted Web workbench PRD and integration ticket. Cloudflare is already merged in #335/#336; its older local copies are not part of this patch.

## Reproduction and regression

Read-only production snapshot inspection found Cursor's transcript healthy while the old Settings mapping displayed `not hooked` (Chinese: 未接入). No Hook files were changed.

`tools/tests/agent-integration-regression.sh` passes using the actual app presentation source. It covers a healthy Cursor transcript without Hooks/cloud credentials, Codex rollout with an unverified version, Grok awaiting its first activity, and an unreadable source despite an installed Hook.

The same runner replayed a sanitized capture of the current Mac's observation diagnostics:

- Cursor: receiving, source transcript.
- Codex: needs attention, source rollout (unverified version).
- Grok and Claude: waiting; no received source asserted.

No conversation text or credentials are stored in this document. Local replay evidence: `.scratch/language-restart/live-diagnostics.json` and `regression.log` in the `language-restart` worktree.

## Build and runtime acceptance

- XcodeGen + Debug macOS build: **BUILD SUCCEEDED** (`.scratch/language-restart/build-final.log`).
- Chinese strings: `plutil -lint` passed; `git diff --check` passed.
- Launched an ad-hoc signed copy with bundle ID `com.vibebuddy.e2e.language-restart`, isolated state and port **18794**. The installed production app was not replaced or restarted.
- Via the native settings UI: English → 简体中文 → Restart VibeBuddy. The process changed from PID 96849 to 97105; `/health` returned `ok` on the same isolated port. The settings window, sidebar and app menus appeared in Chinese. E2E isolation survived the restart.
- Inspected the Chinese Agent integration layout. Replayed real current Codex session metadata and lifecycle/usage events, omitting conversation text, into isolated monitor directories. The UI reported a source requiring attention, matching the rollout version diagnostic; this does not claim support for that unverified version or a successful live Codex control operation.
- Quit the QA app after inspection. No phone, Cloudflare, production Hook configuration or production credential was modified.

## Remaining local work

The primary checkout gained concurrent MiniMax voice edits during this task. Bulk cleanup was stopped before modifying it. Obsolete Cloudflare copies remain there alongside that other session's work; they are not included in this branch. Local agent configuration directories also remain untracked.
