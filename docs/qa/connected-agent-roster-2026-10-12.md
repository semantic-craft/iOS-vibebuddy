# Connected agents remain visible while idle

Date: 2026-10-12 (Asia/Shanghai)

The Cursor rail entry disappeared because all 22 observed sessions were older
than the 24-hour current window. AgentRoster used that filtered set both for
membership and counts. Membership now uses all sessions, configured/observed
sources and dispatch capability, while counts retain the current-session rule.
Mac and iPhone consume the same projection; no snapshot schema changed.

## Verification

- Baseline: d260da04. Scoped source patch SHA-256: f603eadd8520156c88c499982e673a81a48884684853236a0babf72e82bfffad.
- Existing pattern regression failed before the fix, then 13 AgentRoster tests
  passed, including idle Cursor and configured/dispatchable agents with no rows.
- Mac Debug build, iOS Simulator build and local docs checks passed.
- Isolated native Mac bundle `com.vibebuddy.e2e.connected-roster`, port 18796,
  restored 20 real Cursor completion records from the local privacy-minimized
  journal. Health returned ok; unauthenticated snapshot returned 401.
- Computer use confirmed `Cursor · 0 sessions`, selection opened a Cursor
  column with zero, and expanding 20 older tasks kept the current count at zero.
- Physical iPhone installation/acceptance has not been run.

Durable sanitized evidence:
`/Users/xianweizhang/Projects/_shared-work/iOS-vibebuddy/connected-agent-roster-20261012/`.

Production installation: completed and verified in the Chinese native UI:
`Cursor · 0 个会话`, with account quota readings still visible. Installed
version/build: 1.3.46 / 64; executable SHA-256:
`0f4cc75abb3c98a3ec4b923ff9cdd5d463c42ac55fccf4dc3d8bb5e69ef5b174`.
The successful installer receipt is retained with the durable evidence.
The prior bundle remains at
`/Applications/.VibeBuddyMacApp.app.install.lPRjKX/previous.app`.

The first install attempt stopped before replacement because the old app did
not exit on SIGTERM. Its explicit quit also stayed pending. After confirming
the exact installed PID, it was stopped and the normal installer retried;
the second receipt reports installed and the unique production listener healthy.
No installer behavior was changed in this task.
