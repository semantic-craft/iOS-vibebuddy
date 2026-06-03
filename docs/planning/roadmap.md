# vibebuddy — Roadmap

**Last Updated**: 2026-06-03

Phased so each step ends at something runnable and verifiable. No hard dates (personal project); order matters more than calendar. Each phase notes the skills it leans on and a concrete Definition of Done (DoD).

## Phase A — Foundations (shared model)

- `git` repo (done) + monorepo layout.
- `VibeBuddyKit` Swift package: `AgentKind`, `SessionStatus`, `WaitKind`, `AgentSession`, `Snapshot`, `ServerEvent`, `PairingPayload`.
- Lock the wire protocol (REST + WS frames).
- **Skills**: `to-issues` (slice the work), `tdd-feature` + `test-generator` (decoding tests first), `concurrency` (Sendable model).
- **DoD**: `swift test` green — `Snapshot` / `ServerEvent` / `PairingPayload` round-trip encode→decode.

## Phase B — VibeBuddyMac core (headless logic first)

- Hook intake `POST /hook`; the **Reducer** (`[HookEvent] → [AgentSession]`); **TranscriptReader** (JSONL tail → model/tokens/summary); WebSocket **Broadcaster**; bearer-token gate; `GET /snapshot|/ws|/health`.
- Pick the server lib (Hummingbird 2 vs Network.framework) behind a `Server` protocol.
- `hooks/` installer that writes the fail-open curl into Claude Code `settings.json`.
- **Skills**: `tdd-feature` (reducer + transcript tests on recorded fixtures), `concurrency`, `logging-setup`, `coding-best-practices`.
- **DoD**: run a real Claude Code session → `curl localhost:PORT/snapshot` (with token) shows it correctly classified through working → needsResponse → done; reducer/transcript unit tests pass; Claude Code unaffected when the app is off.

## Phase C — VibeBuddyMac menu-bar UI + pairing

- `MenuBarExtra` status glance (counts per bucket), port config, launch-at-login, **"Show pairing QR"** window (encodes `PairingPayload`).
- **Skills**: `coding-best-practices`, `ui-review`.
- **DoD**: menu bar shows live counts; the QR renders and decodes to the right `{host, port, token}`.

## Phase D — iOS app skeleton + networking + pairing

- Xcode iOS app depending on `VibeBuddyKit`; **scan QR** (camera) → store `PairingPayload` in Keychain; WebSocket client + REST snapshot + reconnect (snapshot-on-reconnect).
- **Skills**: `networking-layer` (protocol-based transport, fake for tests), `settings-screen` (connection/pairing screen), `concurrency`.
- **DoD**: in Simulator (and on device) the app pairs by QR and receives live `ServerEvent`s from the running Mac app; a fake transport drives the same store in tests.

## Phase E — Dashboard UI + notifications

- Three-section grouped dashboard (需回应 / 进行中 / 已完成), session cards (project · branch · model · summary · time-in-status), empty + disconnected/reconnecting states.
- Local notification (`UNUserNotificationCenter`) when a session enters `needsResponse`.
- **Skills**: `navigation-patterns`, `ui-review`, `accessibility-generator`, `run-simulator` (visual verify), `logging-setup`.
- **DoD**: on a real iPhone over the same WiFi, the three sections populate and update live within ~1–2s; a blocked session fires a notification.

> ─────────── **v1 complete & usable** ───────────

## Phase F — v1.5

- **Codex adapter**: second source normalized into the same `AgentSession` (Codex hook/notify surface).
- **Live Activity / Dynamic Island**: live counts of 需回应 / 进行中 — the "vibe island" payoff.
- Optional: context-window % + quota/limit warnings (concept from Claude-Code-Usage-Monitor) on top of `tokens`.
- **Skills**: `live-activity-generator`, `background-processing`.

## Future — v2

- **Tailscale remote**: the pairing QR encodes the `100.x` IP — no code change.
- **Remote approve / answer** from the phone (bidirectional, structured — cleaner than screen-scraping). Reuses the existing token.
- **APNs** closed-app push for "needs response" when the app is killed (`push-notifications`).
- Home-screen widgets; snapshot caching (`persistence-setup`); App Store prep.

## Milestones

| # | Milestone | Phases | Proves |
|---|---|---|---|
| M1 | Shared model compiles & tests pass | A | Wire contract is real |
| M2 | Mac classifies a live Claude Code session | B | Detection works end-to-end (headless) |
| M3 | Menu bar + QR pairing | C | Mac-side glance + connect UX |
| M4 | Phone pairs and streams | D | Transport works on device |
| M5 | Three-bucket dashboard + notifications | E | **v1 done** — the three questions answered on the phone |
| M6 | Codex + Dynamic Island | F | Whole fleet, glanceable without opening the app |

## Skill → phase index

`app-planner`(this planning) · `to-prd`/`to-issues`(spec→tasks) · `tdd-feature`/`test-generator`(A,B) · `concurrency`(A,B,D) · `logging-setup`(B,E) · `coding-best-practices`(B,C) · `ui-review`(C,E) · `networking-layer`(D) · `settings-screen`(D) · `navigation-patterns`(E) · `accessibility-generator`(E) · `run-simulator`(E) · `live-activity-generator`(F) · `background-processing`(F) · `push-notifications`/`persistence-setup`(v2).
