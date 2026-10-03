# Antigravity monitor — THROWAWAY PROTOTYPE

Question: can current Antigravity quota, CLI transcripts/hooks, and desktop RPC
support VibeBuddy's agreed read-only monitoring experience?

This directory is outside the Swift targets. It does not change the installed app,
production hooks, login token, or port 9876. It is not a shipped integration.

## Run

From the repository root, with a **new** private output directory each time:

```sh
python3 VibeBuddyMac/Prototypes/AntigravityMonitor/probe.py /tmp/antigravity-prototype-read
python3 VibeBuddyMac/Prototypes/AntigravityMonitor/drive.py /tmp/antigravity-prototype-task
python3 VibeBuddyMac/Prototypes/AntigravityMonitor/drive.py /tmp/antigravity-prototype-long long
```

`probe.py` reads actual quota using the signed-in `agy`, discovers same-user
Antigravity desktop language servers, and queries their read-only session index.
It exports hashed existing session IDs and schema, not conversation bodies or tokens.
Loopback TLS handling is restricted to 127.0.0.1 with proxies/redirects disabled.

`drive.py` creates a disposable workspace with passive project-local hooks and
runs a real read-only agent task. It consumes normal model quota, creates an agent
conversation, and saves that synthetic task's hook/stream/transcript evidence.
Its bounded subprocess is terminated on timeout. It does not configure global hooks.
Short and full transcript result fidelity are checked separately: the short log
can contain `truncated_fields: ["content"]`.

`replay.py EVIDENCE_DIRECTORY` normalizes the **specific captured** CLI and desktop
question/cancellation examples from this run; it expects the named evidence files
listed in the verdict. It is not a general live monitor or an automated UI driver.

Open `demo.html` directly for an offline, in-memory walkthrough. It distinguishes
real observed signal shapes from simulated disconnection/failure/background cases.
It sends nothing and controls no agents. Python/JavaScript syntax was checked.
Automated browser interaction was not verified: the browser policy rejected the
local file URL. No alternate browser or HTTP workaround was attempted.

## Result and preservation

See [the verdict](../../../docs/planning/backlog/antigravity-monitor/PROTOTYPE.md).
Original evidence and a source snapshot live at
`~/Projects/_shared-work/iOS-vibebuddy/antigravity-prototype-20261004/`.
Prototype sources remain uncommitted, outside production targets. No prototype
branch was committed or pushed; the user's repository rules require explicit
commit authorization. The main working tree contains the decision record and these
reviewable local sources, not a deployed integration.
