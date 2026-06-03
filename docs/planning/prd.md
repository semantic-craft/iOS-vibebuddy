# vibebuddy — PRD

**Last Updated**: 2026-06-03
*(Synthesized from the planning conversation, in the style of the `to-prd` skill. No issue tracker is configured for this repo, so the PRD is filed here rather than published as a ticket.)*

## Problem Statement

I run several Claude Code / Codex sessions at once, across different projects. To know what's happening I have to keep tabbing between terminals on my Mac. I lose track of which agent has finished, which is blocked waiting for my permission or answer, and which is still grinding. The cost is real: a session sits blocked for minutes because I didn't notice it needs me, and "ready for the next step" moments slip by.

## Solution

A phone I can glance at. vibebuddy puts every running session on my iPhone, grouped into exactly the three buckets I care about — **needs my response**, **still working**, **done** — updated live over my own WiFi, and it notifies me when a session crosses into "needs my response." No more babysitting terminals; the ball-in-my-court moments come to me.

## User Stories

1. As a multi-session agent user, I want to see all my active Claude Code sessions in one list on my phone, so that I don't have to tab between terminals on my Mac.
2. As a user, I want sessions that need my response grouped at the top, so that I act on blockers first.
3. As a user, I want to see which sessions are still working, so that I know what to leave alone.
4. As a user, I want to see which sessions have finished their turn, so that I know what's ready for my next instruction.
5. As a user, I want each session card to show its project and branch, so that I can tell which piece of work it is.
6. As a user, I want each card to show the model in use, so that I can tell a Claude session from a Codex one and which model.
7. As a user, I want to see the last thing the agent said (a short snippet), so that I have context without opening the Mac.
8. As a user, when a session needs my response, I want to see *why* (a permission request vs. a question), so that I know what kind of action is expected.
9. As a user, I want to see how long a session has been waiting, so that I can prioritize the one that's been blocked longest.
10. As a user, I want a local notification when any session enters "needs my response," so that I'm pulled in even when not staring at the app.
11. As a user, I want the list to update within a second or two of a real state change, so that it feels live.
12. As a user, I want to pair by scanning a QR shown by the Mac menu-bar app, so that I connect without typing an IP and the app reconnects automatically afterward.
13. As a user, I want the app to show a clear "disconnected / reconnecting" state, so that I trust what I'm seeing is current.
14. As a user, I want the app to pull a fresh full snapshot on reconnect, so that I never see stale state after my phone slept.
15. As a user, I want Claude Code to keep working normally even if the daemon is off, so that monitoring never risks my actual work.
16. As a user, I want token / context usage on a session, so that I can spot one approaching its context limit.
17. As a user, I want sessions to disappear shortly after they truly end, so that the list reflects reality.
18. As a user (v1.5), I want Codex sessions shown alongside Claude Code with the same buckets, so that my whole agent fleet is in one place.
19. As a user (v1.5), I want a Live Activity / Dynamic Island showing how many sessions need me, so that I see it without opening the app.
20. As a user (v2), I want to reach the dashboard when away from my home WiFi via Tailscale, so that I can check status anywhere.
21. As a user (v2), I want to approve/deny or answer a blocked session from my phone, so that I can unblock work without returning to the Mac.

## Implementation Decisions

- **Three Swift units in a monorepo**: `VibeBuddyKit` (shared Codable wire model), `VibeBuddyMac` (SwiftUI `MenuBarExtra` app — menu-bar glance, port config, launch-at-login, pairing QR, and the embedded server), `VibeBuddyApp` (SwiftUI iOS). See [architecture.md](./architecture.md).
- **Wire model** is the contract: `AgentSession` (id, agent, project, branch, model, status, waitKind, summary, tokens, statusSince, updatedAt), `Snapshot`, a `ServerEvent` enum (`snapshot` / `sessionUpdated` / `sessionRemoved`), and `PairingPayload` (host, port, token).
- **Status is derived by a pure reducer** over Claude Code hook events. `needsResponse` is driven by the `Notification` hook (not by counting `PreToolUse`), `done` by `Stop`, otherwise `working`. Priority `needsResponse > working > done`.
- **Daemon is non-blocking and read-only.** Hooks POST and return immediately; the daemon only observes. (m5-paper-buddy blocked `PreToolUse` to relay hardware approvals — not needed here.)
- **Transport v1**: token-gated LAN HTTP (`/snapshot`) + WebSocket (`/ws`) + open `/health`, bound to `0.0.0.0:PORT`. The phone **pairs by scanning a QR** the Mac menu-bar app shows, encoding `{host, port, token}` (stored in Keychain on both sides); Tailscale is a later value carried by the same QR.
- **Hook install** mirrors m5's fail-open `curl ... || true` pattern, written into Claude Code `settings.json` by a script under `hooks/`.
- **Server library** chosen in Phase B behind a `Server` protocol (Hummingbird 2 or Network.framework).
- **Concepts borrowed, code not**: transcript-tail parsing (m5), multi-agent `SessionState` reducer (open-vibe-island) — re-implemented lean in Swift.

## Testing Decisions

- **Test external behavior, not internals.** The headline behaviors: a recorded hook sequence produces the right per-session statuses; a snapshot round-trips through encode/decode; the app shows the right sections given a stream of `ServerEvent`s.
- **Highest seam = the reducer.** It's a pure `[HookEvent] -> [AgentSession]` function — feed fixtures (a permission flow, a normal finish, two interleaved sessions), assert grouping. Most logic lives here and needs no I/O.
- **TranscriptReader** tested against small fixture JSONL tails for model/tokens/summary extraction.
- **App layer** tested through a protocol-based fake transport (per the `networking-layer` skill) that emits canned events — no live daemon required.
- **Prior art**: tests follow Swift Testing (`@Test`) per the `test-generator` / `tdd-feature` skills.

## Out of Scope

- Any remote *control* of agents (approve/deny/answer) — v2, and gated on auth.
- Strong auth / encryption beyond the v1 LAN bearer token — v2, with Tailscale.
- Closed-app push via APNs — v2.
- Home-screen widgets, and the Live Activity / Dynamic Island — v1.5 after the core works.
- Agents other than Claude Code (v1) and Codex (v1.5).
- App Store distribution, onboarding flows, settings beyond the connection field.
- iPad / Mac Catalyst layouts.

## Further Notes

- Reference projects: `op7418/m5-paper-buddy` (hook→state→device, Claude Code only, e-ink) and `Octane0411/open-vibe-island` (macOS notch, source-agnostic `SessionState`, 10+ agents). vibebuddy = their detection concept, re-pointed at a phone over the user's own network, reduced to three buckets.
- `vibecodeapp.com` was evaluated and is unrelated (an AI no-code app builder).
- The name's "vibe island" lineage makes the v1.5 Dynamic Island feature a natural payoff.
