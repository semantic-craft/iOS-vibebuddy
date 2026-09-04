# vibebuddy — Overview

**Last Updated**: 2026-09-04
**Status**: Implemented (personal tool; public Mac release is v1.0)

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
| Interaction | **Remote approve / answer; APNs + local notifications; Widget / Live Activity; Watch companion** | Token still gates viewing. Remote control reuses the same bearer token. Closed-app updates go through APNs. |
| Sources | **Claude Code first, Codex fast-follow** | Daemon is source-agnostic (`agent` field per session) from day one; Claude Code's hooks are richest and map cleanest. |
| Detection model | **Borrow concepts**, not code, from m5-paper-buddy (transcript tail parse, RUNNING/WAITING sets) + open-vibe-island (multi-agent `SessionState` reducer) | Re-implement lean, in Swift, non-blocking. |

## Scope

**In:**
- **macOS menu-bar app** (`VibeBuddyMac` / `VibeBuddyMacApp`): receives hook events, derives per-session state, parses transcript tail, broadcasts over token-gated LAN WebSocket + REST snapshot, and shows a pairing QR + status glance.
- iOS app: **scan QR to pair**, three-section live dashboard, remote approve / answer, local notifications + **APNs**, **Widget / Live Activity**.
- **watchOS companion** on a paired personal Watch (no direct Mac transport; iPhone relays).
- Hook routes require the install bearer token (**ADR-0009**).

**Out (deferred):**
- Tailscale remote access (the token is already present; Tailscale is a later QR host value).
- App Store / TestFlight distribution (personal Xcode install this round).
- Agents beyond the current adapter set.

## Key Risks & Mitigation

1. **iOS background limits** — a suspended app can't hold a WebSocket. *Mitigation*: APNs + Live Activity keep closed-app updates alive; the WebSocket is for foreground.
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
