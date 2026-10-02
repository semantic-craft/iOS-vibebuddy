# Mac 1.3.42 local installation — 2026-10-02

The installed shared app is now **1.3.42 (60)**, built from the clean
`codex/grok-monitoring-release` worktree. Release metadata and notes are in
`7b0591d2`; product implementation and the passing scoped checks are unchanged
from [the mobile delivery](grok-mobile-1.3.34.md).

## Installation

- Release `xcodebuild` succeeded. Developer ID signing, strict deep signature
  verification, and Production CloudKit entitlements succeeded.
- Peer status and worktrees were checked before the build and again immediately
  before replacement. No other VibeBuddy device acceptance session was active;
  other active projects were unrelated to this app's device acceptance.
- The previous 1.3.41 app was backed up before replacement. Its graceful stop
  closed the server but did not exit within the bounded wait. Replacement first
  stopped without modifying the installed bundle, then retried by terminating
  only the verified old app PID, as the existing redeploy procedure does.
- `/Applications/VibeBuddyMacApp.app` was replaced and launched. `/health`
  returned `ok`, and exactly one Mac app process was running.

This is a signed local installation. No new notarization, DMG publication,
Sparkle feed update, PR merge, or App Store/TestFlight submission is claimed.
The original app backup remains in the worktree's
`.scratch/grok-release/InstalledBackup/`.

## Real installed-app acceptance

Computer Use drove Settings → Agent integration in the installed app. The new
Grok monitoring switch was initially off, consistent with the stored monitoring
intent; account quota remains a separate setting. Enabling the switch succeeded
and configured Grok activity hooks automatically. The switch is left on.

The native UI now shows:

- Grok Build in the dashboard's agent selector, even with zero formal tasks.
- `glaux-book` as **已发现，等待接入**.
- Settings status **已连接：0 个 · 等待活动上报：1 个**, with `/hooks` → `r`
  reload guidance. Selecting Grok preserves the discovery card.

A read-only authenticated probe of the actual installed server verified both
HTTP `/snapshot` and the WebSocket's first `ServerEvent.snapshot` frame:
`grokMonitoring` is present, `enabled` and `configured` are true, one discovery
is reported, and the formal Grok task count remains zero. The earlier installed
1.3.41 HTTP snapshot did not contain this field. Existing Codex sessions resumed
through their real rollout data after installation.

The token was used only in memory to authenticate the local probe; only selected
status fields were retained. No token or complete snapshot was printed or saved.

## Remaining native-session observation

The existing Grok session has not loaded the newly installed hooks. Computer
Use refused the Ghostty app for safety reasons; no alternative terminal input
automation was attempted. Its owner can run `/hooks`, press `r`, then let the
next real activity report connect it; a new Grok session also loads the hooks.
Discovery alone is not reported as a connected task.

Hermes retains the installed iPhone **1.3.34 (69)**. Phone visual acceptance
remains unavailable because iPhone Mirroring reports the phone is in use.
The real server's first-frame check proves the new data is available, not that
the physical phone has displayed it.

Build, signing, installation, and selected before/after HTTP/WebSocket probe
logs are preserved under
`~/Projects/_shared-work/iOS-vibebuddy/2026-10-02-grok-mobile-release/`.
Native UI evidence is in this Codex turn. Primary-checkout pending changes were
excluded from this build and preserved.
