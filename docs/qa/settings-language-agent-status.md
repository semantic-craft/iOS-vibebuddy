# Settings language restart and agent status — 2026-10-01

## Change

- General → Language now offers **Restart VibeBuddy**. The helper waits for normal process exit and the single-instance lock release before reopening the exact app bundle.
- Agent integration shows observation status separately from Hook configuration. A missing Hook no longer implies a missing integration. Receiving activity does not claim remote-control support.
- Preserve the previously uncommitted Web workbench PRD and integration ticket. Cloudflare is already merged in #335/#336; its older local copies are not part of this patch.

## Reproduction and regression

Read-only production snapshot inspection found Cursor's transcript healthy while the old Settings mapping displayed `not hooked` (Chinese: 未接入). No Hook files were changed.

`tools/tests/agent-integration-regression.sh` passes using the actual app presentation source. It covers a healthy Cursor transcript without Hooks/cloud credentials, Codex rollout with an unverified version, Grok awaiting its first activity, an unreadable source despite an installed Hook, and fresh/stale hosted Grok ACP evidence omitted from aggregate diagnostics.

The same runner replayed a sanitized capture of the current Mac's observation diagnostics:

- Cursor: receiving, source transcript.
- Codex: needs attention, source rollout (unverified version).
- Grok and Claude: waiting; no received source asserted.

No conversation text or credentials are stored in this document. Local replay evidence: `.scratch/language-restart/live-diagnostics.json` and `regression.log` in the `language-restart` worktree.

## Build and runtime acceptance

- XcodeGen + Debug macOS build: **BUILD SUCCEEDED** (`.scratch/language-restart/build-final.log`).
- Chinese strings: `plutil -lint` passed; `git diff --check` passed.
- Launched an ad-hoc signed copy with bundle ID `com.vibebuddy.e2e.language-restart`, isolated state and port **18794**. The installed production app was not replaced or restarted.
- Via the native settings UI: English → 简体中文 → Restart VibeBuddy. The process changed from PID 23001 to 23133 (final post-review build); `/health` returned `ok` on the same isolated port. The settings window, sidebar and app menus appeared in Chinese. E2E isolation survived the restart.
- Inspected the Chinese Agent integration layout. Replayed real current Codex session metadata and lifecycle/usage events, omitting conversation text, into isolated monitor directories. The UI reported a source requiring attention, matching the rollout version diagnostic; this does not claim support for that unverified version or a successful live Codex control operation.
- Quit the QA app after inspection. No phone, Cloudflare, production Hook configuration or production credential was modified.

## Remaining local work

The primary checkout gained concurrent MiniMax voice edits during this task. Bulk cleanup was stopped before modifying it. Obsolete Cloudflare copies remain there alongside that other session's work; they are not included in this branch. Local agent configuration directories also remain untracked.

## Independent review

Grok Build (`grok-4.7-build-fast`, `xhigh`) reviewed immutable range `a7ad6a04..d784bb92`, verdict **MERGE WITH FIXES**. Applied in `46d8d11f`: prioritize non-cloud source faults over healthy/silent siblings; prefer waiting state over Hook installation; explicitly localize the Hook subtitle; preserve demo mode on relaunch; remove the arbitrary quit timeout; show faulted source names without timestamps; use an explicit HStack. The optional cloud channel remains independent of healthy local monitoring.

The Chinese subtitle already translated during the first runtime check, so its alleged failure was not reproduced; the explicit localized-key change removes ambiguity. Added combined-source and wired-idle regressions. The author also added missing hosted Grok ACP session evidence in `b328880a`, with aging and diagnostic precedence checks.

Final Debug build and targeted regressions pass. Repeated the real language-picker/restart flow after these fixes; Chinese UI, changed PID and isolated health recovery passed again. Removed the stopped QA bundle, disposable state and isolated preferences; retained sanitized diagnostic replay and build/test logs.

Grok 的定向复核覆盖 `46d8d11f` 的最终代码，正常结束（`end_turn`），结论 **MERGE**：4 项发现和 3 项细节全部 FIXED，新增 Grok ACP 补充逻辑无具体回归。该只读复核不代替本文记录的运行验收。
