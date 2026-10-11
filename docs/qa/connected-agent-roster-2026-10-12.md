# Connected agents remain visible while idle

Date: 2026-10-12 (Asia/Shanghai)

Current status: the physical-iPhone acceptance gap is closed. On merged
`main` commit `3b4f03cd` (PR #356), the updated iPhone app retained Cursor with
zero current sessions while connected live to Helios. Details are recorded in
the physical-iPhone section below.

The Cursor rail entry disappeared because all 22 observed sessions were older
than the 24-hour current window. AgentRoster used that filtered set both for
membership and counts. Membership now uses all sessions, configured/observed
sources and dispatch capability, while counts retain the current-session rule.
Mac and iPhone consume the same projection; no snapshot schema changed.

## Verification

The native isolated run and installed Chinese UI evidence below were collected
on the original `d260da04` baseline plus this patch (`a6d5adc2`), before the
change was cherry-picked onto `main`. Their binary hash does not describe the
complete rebased PR app. On the independent PR head `f611df5d`, the same 13
AgentRoster tests, Mac Debug build, iOS Simulator build and docs checks passed;
installed-app and physical-iPhone acceptance were not repeated at that head.

- Baseline: d260da04. Scoped source patch SHA-256: f603eadd8520156c88c499982e673a81a48884684853236a0babf72e82bfffad.
- Existing pattern regression failed before the fix, then 13 AgentRoster tests
  passed, including idle Cursor and configured/dispatchable agents with no rows.
- Mac Debug build, iOS Simulator build and local docs checks passed.
- Isolated native Mac bundle `com.vibebuddy.e2e.connected-roster`, port 18796,
  restored 20 real Cursor completion records from the local privacy-minimized
  journal. Health returned ok; unauthenticated snapshot returned 401.
- Computer use confirmed `Cursor · 0 sessions`, selection opened a Cursor
  column with zero, and expanding 20 older tasks kept the current count at zero.
- Physical iPhone installation/acceptance was pending during this initial Mac
  run; the subsequent merged-source acceptance below closes that gap.

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

## Physical iPhone acceptance (2026-10-12 06:53 Asia/Shanghai)

- Source: merged `main`, `3b4f03cd8020062e9c5e79fbf5cf64b865294f64` (PR #356).
- Built and signed VibeBuddy **1.3.37 / build 72**, bundle `com.vibebuddy.app`,
  from the clean source. Executable SHA-256:
  `77ea08b91b064f391d0e78508ec206cb440fddc6b9ed343acd56660bf6546920`.
- Updated the app in place on a physical **iPhone 17 Pro Max** using CoreDevice;
  the installation receipt confirmed success. The existing Helios pairing
  remained available. This was a local development installation.
- PUA READY confirmed an unlocked phone, usable control session, readable
  foreground app and viewport before the UI drive.
- In the ordinary connected app, the horizontal agent strip retained
  **Cursor · 0**. Selecting Cursor kept that entry visible and displayed
  **Nothing running** / **Cursor has nothing running right now.** The connection
  label remained **已连接**. This establishes a zero-current-session state
  without hiding the agent, rather than relying on a cached offline screen.
- No app source or preference changes were needed for this acceptance. No
  App Store or TestFlight release was performed.

Durable local evidence under the existing run's `iphone/` directory:
`metadata.json`, `install.json`, `acceptance.md`,
`cursor-zero-all-agents.jpg` and `cursor-zero-selected.jpg`.
Device identifiers, provisioning details, private screen captures and logs
remain outside Git. The prior Mac evidence retains its original baseline;
this later phone acceptance is on the merged source.
