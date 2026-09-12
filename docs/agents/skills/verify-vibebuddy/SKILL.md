---
name: verify-vibebuddy
description: "Drive VibeBuddy (Mac menu-bar companion, headless vibebuddyd on the LAN HTTP surface, iPhone, Watch) the way a user does. Use to launch an isolated daemon, prove dashboard sessions, phone pairing, remote approval, question reply, or iPhone Demo, and capture evidence without touching the installed app on :9876."
---

# Verify VibeBuddy

VibeBuddy is a personal-use **Mac, iPhone, and Apple Watch** companion for Claude Code, Codex, Grok Build/Bot, and Cursor usage. Users touch native apps, not a website. The Mac is the hub: the menu-bar app embeds the same HTTP + WebSocket server as the headless `vibebuddyd` (`docs/getting-started.md`). Phones and hooks talk to that server with a bearer token (ADR-0009).

This skill drives an **isolated** `vibebuddyd` (the repo's documented headless path) and, on a Mac with simulators, the iPhone Demo. It does **not** replace `/Applications`, bind **:9876**, or write the login `~/Library/Application Support/vibebuddy/` token.

Read `features/README.md` before a run. Drive the mapped feature file, not a convenient substitute.

Helper (executable; invoke only via these paths):

```bash
ctrl="docs/agents/skills/verify-vibebuddy/helpers/control-vibebuddy"
```

## Launch

Documented user/dev start for the hub:

```bash
swift run --package-path VibeBuddyMac vibebuddyd --pair   # production-shaped; defaults to :9876
```

Verification start — isolated port, disposable HOME, never :9876:

```bash
export VERIFY_RUN_ID="${VERIFY_RUN_ID:-vb-$(date +%Y%m%dT%H%M%S)}"
export VIBEBUDDY_QA_PORT="${VIBEBUDDY_QA_PORT:-18765}"   # must not be 9876
export VERIFY_EVIDENCE_DIR="${VERIFY_EVIDENCE_DIR:-$PWD/.scratch/verify-vibebuddy/$VERIFY_RUN_ID}"
"$ctrl" launch            # or: "$ctrl" launch --pair
```

Ready when **both** are true:

- `GET http://127.0.0.1:$VIBEBUDDY_QA_PORT/health` returns `ok` (unauthenticated).
- `vibebuddyd: listening on 0.0.0.0:<port>` is in the run's `daemon.log`.

The helper builds with `swift build --package-path VibeBuddyMac --product vibebuddyd` (Swift 6, macOS 14+, Xcode 26.6 / XcodeGen for the GUI apps — `docs/getting-started.md#build-from-source`). It restores `VibeBuddyMac/Package.resolved` after the build, matching `tools/watch-live-qa.sh`.

`--pair` opens the same **120-second** registration window as Mac **Pair a phone** / `vibebuddyd --pair`.

Teardown is **Cleanup** below. Keep the daemon up for the whole drive; do not restart between doctor and the first action unless doctor fails.

**Host gap:** `VibeBuddyMac/Package.swift` is `platforms: [.macOS(.v14)]`. Linux cannot compile or run `vibebuddyd`, the menu-bar app, or the iPhone/Watch apps. If `launch` prints `blocked: host is Linux`, stop. Do not invent a web/CLI stand-in. Report that acceptance gap.

**Do not** launch the installed menu-bar app, `open VibeBuddyMacApp.xcodeproj` Run, or a second production instance. A second production Mac app takes the `SingleInstanceLock` and returns to the existing dashboard (`docs/qa/mac-1.3.3.md`). Isolated E2E GUI requires bundle id `com.vibebuddy.e2e.<id>` plus `VIBEBUDDY_E2E_*` (`VibeBuddyKit` `E2ERunConfiguration`) and is out of this skill's default path.

## Doctor

Run before the first drive, after any surprise, and on every fresh session:

```bash
"$ctrl" doctor
```

Worth driving only when the report includes all of:

- Disposable `HOME` is `<state>/home`, not the login home.
- The recorded PID is alive and is `vibebuddyd`.
- That PID owns `VIBEBUDDY_QA_PORT` (not 9876).
- `GET /health` → `ok`.
- `GET /snapshot` without a token → `401`.
- `GET /snapshot` with `Authorization: Bearer <run token>` → `200` JSON (`sessions`, optional `sourceID`).

If doctor fails, do not drive. `cleanup`, fix the skill/host, `launch` again, `doctor` again.

## Drive

The phone's user path **is** this HTTP surface (`/snapshot`, `/decision`, `/answer`, `/device`, `/ws`). CLI hooks use `/hook`, `/approval`, `/terminal` with the same token (header or `?token=`). Prefer those routes and snapshot fields over coordinates.

Stable handles:

| Surface | Handle |
| --- | --- |
| Health | `GET /health` body `ok` |
| Snapshot | `GET /snapshot` → `sessions[].id`, `.status` (`needsResponse` / `working` / `done`), `.waitKind` (`permission` / `question`), `.project`, `.pendingApproval.id`, `.pendingQuestion` |
| Hook ingest | `POST /hook?agent=claude` (or `codex`, `grok`, …) |
| Held approval | `POST /approval` then `POST /decision` `{"approvalId","decision"}` with `allow` / `deny` / `alwaysAllow` / `allowSession` |
| Question | `POST /answer` `{"sessionId","answer"}` (optional `expectedQuestionId`) |
| Pairing | `POST /device` during the 120s window; `403` outside it |
| Mac UI | Footer **Dashboard**, **Pair a phone**, **Scan this in the vibebuddy iOS app within 2 minutes.**, QR `accessibilityLabel` **Pairing QR code**, **Approve** / **Deny** |
| iPhone UI | **Scan to pair**, **See the demo (no Mac needed)**, **Approve**, **Deny**, **Reply**, demo title **Demo**, demo sessions `demo-edit` / `demo-build` / `demo-work` |
| iPhone env | `VIBEBUDDY_HOST` / `VIBEBUDDY_PORT` / `VIBEBUDDY_TOKEN` (launch-only, not saved); `VIBEBUDDY_DEMO=1` |

```bash
"$ctrl" hook --agent claude --json '{"hook_event_name":"SessionStart","session_id":"vb-verify-dash","cwd":"/tmp/verify-gateway"}'
"$ctrl" snapshot --pretty
"$ctrl" approval --session-id vb-verify-ap --cwd /tmp/verify-gateway --tool Bash --command 'rm -rf /tmp/vibebuddy-verify-should-ask'
"$ctrl" approval --json '{"hook_event_name":"PreToolUse","session_id":"vb-verify-askq","cwd":"/tmp/verify-docs-review","tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"Which revision style should I use?","options":[{"label":"Short"}]}]}}'
"$ctrl" wait-for --session-id vb-verify-ap --field pendingApproval   # prints the approval id
"$ctrl" decision --approval-id '<that id>' --decision allow
"$ctrl" answer --session-id vb-verify-q --text 'use the short revision'
"$ctrl" device --name 'Verify Phone' --device-id 'verify-phone-1'
"$ctrl" sim-demo
```

`Read` / `Grep` / `Glob` PreToolUse calls are auto-allowed (`ApprovalShortCircuit`) and never become a card. Use `Bash` (or another non-read-only tool) without `bypassPermissions`. `AskUserQuestion` is the one tool in `readOnlyTools` that still raises a card — the question branch runs before the short-circuit gate. `/approval` **holds ~25s**, and the card lands a moment *after* the holding POST returns, so use `wait-for` rather than one snapshot, as `tools/watch-live-qa.sh` does with its own sleep.

Recipes live in `features/`. Drive one mapped feature per proof unless a later run is covering the map.

## Evidence

Named location (survives cleanup):

```text
$VERIFY_EVIDENCE_DIR/<feature-id>/
```

Default: `.scratch/verify-vibebuddy/<VERIFY_RUN_ID>/` (`.scratch/` is gitignored). Generation proofs for this Cloud Agent also copy into the assigned store `media/` path when `VERIFY_EVIDENCE_DIR` is set there.

```bash
"$ctrl" evidence --label dashboard-sessions
```

Writes `meta.txt`, `health.txt`, `snapshot.json`, and a daemon log tail. Transcripts of launch/doctor/cleanup append to `$VERIFY_EVIDENCE_DIR/transcripts/`.

Proof standards:

- Exercise the real user path: hook ingest + snapshot (what the dashboard shows), `/decision` (what **Approve** sends), `/device` (what pairing registration sends). Do not poke `SessionStore` in-process or call test-only endpoints.
- Capture the action **and** the resulting snapshot (status / `pendingApproval` / registry), not only the final screen.
- Side effects: `sessions[]` in `/snapshot`, `device-registry.json` after a paired `POST /device`, `/approval` response body containing `permissionDecision` after a decision.
- UI proof on a Mac: screenshot of the isolated iPhone Demo or isolated daemon-backed simulator with the app identity visible (`Demo` or the seeded project name). Menu-bar pixels are not reachable from CUA without extra setup (`docs/qa/mac-1.3.3.md`).
- Never paste pairing tokens, QR payloads, or API keys into issues, PR bodies, or screenshots (`CONTRIBUTING.md`).
- iPhone Demo (`VIBEBUDDY_DEMO=1` / **See the demo**) proves chrome only. It does not prove a live Mac, APNs, or a real agent.
- Mocks only at production boundaries the app already isolates (no VibeBuddy cloud). Do not stub `/health` or `/snapshot`.

## Cleanup

Kill only the PID recorded in this run's `run.env`. Never `killall vibebuddyd` or the installed app.

```bash
"$ctrl" cleanup
```

Removes `/tmp/vibebuddy-verify-<id>` (HOME, journal, pid, daemon log). **Does not** delete `$VERIFY_EVIDENCE_DIR`. After cleanup, confirm the evidence files still exist at that path. If `VERIFY_EVIDENCE_DIR` is inside the state dir, cleanup refuses.

After a failed iteration, run `cleanup` before the next `launch` so ports and held `/approval` curls are not stranded.

## Helpers

All commands above are `$ctrl <subcommand>`. The script is `helpers/control-vibebuddy` and must stay executable (`chmod +x`). It owns launch, doctor, drive verbs, evidence, sim-demo, and cleanup. Do not reverse-engineer env files by hand; `doctor` and `evidence` print the run identity.

Isolation: two verification runs can coexist if they use different `VERIFY_RUN_ID` and `VIBEBUDDY_QA_PORT` values. They must not share HOME or the production token file. They must not use 9876.

Existing Mac-only QA that this skill wraps rather than replaces: `tools/watch-live-qa.sh` (isolated daemon + simulators), `scripts/phone_qa_harness.sh` (live phone against a daemon — defaults to :9876, so point it at the isolated URL or do not use it here).
