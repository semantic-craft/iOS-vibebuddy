# vibebuddy — Overview

**Last Updated**: 2026-06-03
**Status**: Planning (pre-implementation)

## Quick Summary

- **Purpose**: See the live status of all my concurrent Claude Code / Codex sessions on my iPhone, so I always know which need my response, which are still working, and which are done — without staring at the Mac.
- **Target User**: Me (single power-user running several coding-agent sessions at once across projects).
- **Platform**: iOS 26+ app + macOS menu-bar app (SwiftUI `MenuBarExtra`).
- **Project Type**: Personal infrastructure tool.

## Vision

A glanceable phone dashboard that mirrors, in real time, the state machine of every coding-agent session running on my Mac. The hard part — *detecting* session state — is already solved by hooks (proven by `m5-paper-buddy` and `open-vibe-island`); vibebuddy re-targets that signal from an e-ink gadget / Mac notch to my phone over my own network, and reduces it to the three questions I actually care about.

## The Three Questions (the whole point)

| Question | Internal state | Primary signal |
|---|---|---|
| ② Which tasks **need my response**? | `needsResponse` | Claude Code `Notification` hook (permission / waiting-for-input) |
| ③ Which tasks are **still being worked on**? | `working` | between `UserPromptSubmit` and `Stop`; tool activity |
| ① Which tasks are **completed**? | `done` | `Stop` hook fired, not waiting |

Priority when a session could be in two: `needsResponse` > `working` > `done`.

## Key Decisions (locked)

| Area | Decision | Rationale |
|---|---|---|
| Language | **All-Swift** | The Mac menu-bar app and the iOS app share one Codable model set; JSON contract written once. |
| Mac side form (R1) | **SwiftUI `MenuBarExtra` app** (`VibeBuddyMac`) | Mac-side glance + natural home for launch-at-login, port config, and the pairing QR; matches `eul` / open-vibe-island. Embeds hook intake + reducer + WebSocket server. |
| Repo | **Monorepo** `~/Projects/iOS-vibebuddy` with shared `VibeBuddyKit` package | Single source of truth for the wire types. |
| Transport (v1) | **LAN HTTP + WebSocket**, light **bearer token** | App stores `host:port`+token so swapping in a Tailscale IP later needs no code change. |
| Connect UX (R2) | **QR pairing** | Mac shows a QR encoding `host:port` + token; phone scans (no manual IP). Same QR later carries the Tailscale `100.x` IP. |
| Interaction (v1) | **Read-only + local notifications** | Token gates *viewing*; remote *control* still deferred (needs a bidirectional channel). Unidirectional broadcast is simplest and safe. |
| Sources | **Claude Code first, Codex fast-follow** | Daemon is source-agnostic (`agent` field per session) from day one; Claude Code's hooks are richest and map cleanest. |
| Detection model | **Borrow concepts**, not code, from m5-paper-buddy (transcript tail parse, RUNNING/WAITING sets) + open-vibe-island (multi-agent `SessionState` reducer) | Re-implement lean, in Swift, non-blocking. |

## Scope

**In (v1):**
- **macOS menu-bar app** (`VibeBuddyMac`): receives Claude Code hook events, derives per-session state, parses transcript tail for model/tokens/last-message, broadcasts over token-gated LAN WebSocket + REST snapshot, and shows a pairing QR + status glance in the menu bar.
- iOS app: **scan QR to pair**, three-section live dashboard, local notification when a session enters `needsResponse`.

**Out (deferred — see roadmap):**
- Tailscale remote access (the token is already in v1; Tailscale is just a later QR value).
- Remote approve / answer from the phone (needs auth + bidirectional channel).
- True closed-app push via APNs.
- Home-screen widgets; **Live Activity / Dynamic Island** (strong v1.5 once v1 works).
- Agents beyond Claude Code + Codex.

## Key Risks & Mitigation

1. **iOS background limits** — a suspended app can't hold a WebSocket. *Mitigation*: v1 targets foreground/active glances + local notifications while alive; defer true closed-app push to APNs (v2).
2. **"Needs response" false positives/negatives** — distinguishing a real permission/idle wait from normal tool churn. *Mitigation*: drive `needsResponse` from the `Notification` hook (purpose-built for "Claude wants your attention"), not from blindly counting `PreToolUse`.
3. **Codex hook surface differs from Claude Code** — *Mitigation*: source-agnostic model; Codex added as a separate adapter after Claude Code path is proven.
4. **Swift server libs** — picking an HTTP/WS server for the daemon. *Mitigation*: lean default (Hummingbird or Network.framework), decided in Phase B, isolated behind a small server interface.

## Success Metrics

- I can open the app on the same WiFi and within ~1s see every active session grouped correctly.
- When a session blocks for permission/input, my phone notifies me within a few seconds.
- Zero impact on Claude Code if the daemon is down (hooks "fail open").

## Related Documents

- [prd.md](./prd.md) — problem, solution, user stories, decisions
- [architecture.md](./architecture.md) — components, data model, state machine, wire protocol
- [roadmap.md](./roadmap.md) — phased build plan A→F and which skills each phase uses
