# Release integration — macOS 1.3.39 / iOS 1.3.32

2026-10-01 (Asia/Shanghai). Mac build 57; iPhone / Watch build 65.
Branch: `codex/settings-cloudflare-release`.

## Scope

Includes settings UX/DX/AX improvements and Chinese/English language selection,
plus reviewed Cloudflare Access PR #335 (including its unsent-action correction).
Merged in a clean worktree, preserving unrelated planning and uncommitted work in
the original checkout. The single localization conflict keeps both sets of keys.

The owner permanently changed this project's independent reviewer to Grok Build
`grok-4.7-build-fast` / `xhigh`; AGENTS and the review runbook now agree.

## Verified in the integrated candidate

- Computer Use: missing voice key → provider draft → cancel → return to original
  disabled feature; advanced model expansion; readable real Codex permissions and
  raw disclosure; Chinese selection survives restart; Cloudflare setup guide
  opens with the correct isolated local port and independent button identifier.
- The GUI used this coordinator's real Codex rollout, copied into an isolated
  E2E HOME. One real active session appeared in the dashboard. No production
  credentials were changed and no paid model requests were made.
- An isolated daemon on 19849 passed health/authentication checks, all four
  seeded session states, and held approval → allow → working with no pending
  approval. These HTTP checks exercise the actual phone/hook surface; seeded
  events are not claimed to be a real CLI approval session.
- Mac Core: 1154 tests / 150 suites passed. Kit: 499 tests / 97 suites passed.
  Credential draft/save/cancel/failure regression passed.
- Two previous failures are resolved: fixed-date Cursor billing data now uses a
  fixed in-period clock; the decoder permits >100% only for spend_limit, keeping
  malformed ordinary windows unavailable. The original malformed-window test
  remains; 39 focused tests passed before the full run.
- Cloudflare guide AX container identifier no longer overrides its child button.
  Runtime readback confirms `mac-cloudflare-guide`.
- iOS 1.3.32 (65) archive and export succeeded. All four embedded products are
  Apple Distribution signed, share version/build, and pass signature verification.
  Phone production APNs and Time Sensitive entitlements were checked.

## Build environment finding

Xcode export initially failed with “Copy failed”: Apple rsync invoked Homebrew
rsync as its child, which rejected --extended-attributes. Re-running export with
`PATH=/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin` succeeded. No app code or
credentials needed changing. Use this PATH for the candidate's export/upload.

## Evidence and remaining limits

Local logs: `.scratch/release-139/` in the release worktree; quota reproduction and
focused checks: `.scratch/release-quota-tests.log`.
Prior real Cloudflare cellular, HTTPS/WSS, restart and interruption recovery:
[Cloudflare verification](../planning/backlog/cloudflare-access/verification.md).
This run did not repeat that live Tunnel/device setup after its authorized cleanup.

Exact minimum-window sizing, paid provider success, and physical phone/Watch
notification delivery are not established by the checks above. Review, notarization,
publishing, and installed-update results are appended as they finish.
