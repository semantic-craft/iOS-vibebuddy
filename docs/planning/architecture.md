# vibebuddy — Architecture

**Last Updated**: 2026-09-04

## Components

```
Mac
  Claude Code / Codex
      │  lifecycle hooks POST JSON  (curl, "fail open")
      ▼
  VibeBuddyMac  (SwiftUI MenuBarExtra app, depends on VibeBuddyKit)
      • MenuBarExtra UI   → status glance, port config, launch-at-login, "Show pairing QR"
      • POST /hook /approval /terminal  ← bearer token (ADR-0009; query token allowed)
      • Reducer           → derive per-session status (needsResponse/working/done)
      • TranscriptReader  → tail JSONL for model, tokens, last assistant text
      • Broadcaster       → push ServerEvent to WS clients
      • GET /snapshot, WebSocket /ws ← bound to 0.0.0.0:PORT (LAN), bearer-token gated
      • GET /health              ← unauthenticated liveness probe
      │
      │  LAN WebSocket + REST, bearer token  (later: Tailscale 100.x via same channel)
      ▼
iPhone
  VibeBuddyApp  (SwiftUI, depends on VibeBuddyKit)
      • Pairing      → scan QR → {host, port, token, macName?} → ConnectionStore / UserDefaults
      • DashboardStore + WebSocket client (automatic /ws reconnect; server-pushed initial snapshot)
      • Dashboard (3 sections) + remote approve / answer
      • local notifications + APNs; Widget / Live Activity
      • Watch companion (iPhone relays; Watch has no Mac token)
```

Both apps depend on **VibeBuddyKit**, the single source of truth for the wire types.

## Repository Structure (monorepo)

```
iOS-vibebuddy/
├── VibeBuddyKit/        Swift Package — shared Codable models + wire protocol
│   ├── Package.swift
│   └── Sources/VibeBuddyKit/{Models,Protocol}.swift
├── VibeBuddyMac/        Xcode macOS app (SwiftUI MenuBarExtra) — depends on VibeBuddyKit
│                        Hook intake · Reducer · TranscriptReader · Server · menu-bar UI · pairing QR
├── VibeBuddyApp/        Xcode iOS app (SwiftUI) — depends on VibeBuddyKit
├── hooks/               install scripts + hook command for Claude Code / Codex
└── docs/planning/       these documents
```

`VibeBuddyKit` is a local Swift package both Xcode apps reference, so the wire format can never drift.

## Shared Data Model (VibeBuddyKit)

Illustrative shape — exact fields finalized in Phase A via TDD on decoding.

```swift
public enum AgentKind: String, Codable, Sendable { case claudeCode, codex }

public enum SessionStatus: String, Codable, Sendable {
    case needsResponse   // ② your turn — permission / waiting for input
    case working         // ③ actively running
    case done            // ① turn ended, idle
}

public enum WaitKind: String, Codable, Sendable {
    case permission      // blocked on an approve/deny
    case question        // asked you something / idle waiting for input
}

public struct AgentSession: Codable, Identifiable, Sendable, Equatable {
    public let id: String            // agent session id
    public let agent: AgentKind
    public var project: String
    public var branch: String?
    public var model: String?
    public var status: SessionStatus
    public var waitKind: WaitKind?   // non-nil only when status == .needsResponse
    public var summary: String?      // last assistant text, or the permission/question prompt
    public var tokens: Int?          // context usage for the focused turn
    public var statusSince: Date     // entered current status → drives "等待 1m12s"
    public var updatedAt: Date
}

public struct Snapshot: Codable, Sendable {
    public var sessions: [AgentSession]
    public var serverTime: Date
}

// WebSocket push frames
public enum ServerEvent: Codable, Sendable {
    case snapshot(Snapshot)
    case sessionUpdated(AgentSession)
    case sessionRemoved(id: String)
}

// QR pairing payload (encoded in the QR the Mac shows; scanned by the phone)
public struct PairingPayload: Codable, Sendable {
    public var host: String          // LAN IP today, Tailscale 100.x later
    public var port: Int
    public var token: String         // bearer token, stored with this payload in UserDefaults
    public var macName: String?
}
```

## State Machine (hook event → status)

We register these Claude Code hooks and reduce them. Claude's status hooks are fail-open and asynchronous, so they stay off the agent's critical path. Remote approval is a separate, opt-in blocking `PermissionRequest` gate — it fires only when Claude would prompt, answers in that event's `decision.behavior` contract, and is not the default path (nor a read-only daemon).

| Hook event | Effect on session |
|---|---|
| `SessionStart` | upsert session, `status = done`, set project/branch/cwd; remain idle until `UserPromptSubmit` |
| `UserPromptSubmit` | `status = working`, `statusSince = now` |
| `PreToolUse` | stay `working`; record active tool name for the "working" detail |
| `PostToolUse` | stay `working`; clear active tool |
| **`Notification`** | **`status = needsResponse`**; derive `waitKind` from the message ("needs your permission" → `.permission`; "waiting for your input" → `.question`); `summary` = message |
| `Stop` | `status = done` (unless a later event already moved it) |

On every event the daemon also refreshes derived metadata via **TranscriptReader**: seek to the JSONL tail (read last ~128 KB), scan backward for the latest `assistant` message → `model`, `usage.input_tokens + output_tokens` → `tokens`, and collapsed text → `summary` (when not overridden by a permission/question). Git project/branch read from `cwd` with a short TTL cache. (Concepts from `m5-paper-buddy`'s `claude_code_bridge.py`.)

**Why `Notification` not `PreToolUse`-counting:** `PreToolUse` fires for every tool, including auto-approved ones, so it can't by itself mean "needs you." Claude Code's `Notification` hook is purpose-built to fire when Claude wants the user's attention — the correct, low-false-positive signal for `needsResponse`. (Independently confirmed by onikan27/claude-code-monitor's Running/Waiting/Done model.)

## Connection & Pairing

1. `VibeBuddyMac` generates a random `token` on first run. `TokenStore` persists it in the owner-only (`0600`) file `~/Library/Application Support/vibebuddy/token`, and the server binds to `0.0.0.0:PORT`.
2. The menu bar's **"Show pairing QR"** renders a QR encoding `PairingPayload { host, port, token, macName? }` (host = current LAN IP; later a Tailscale `100.x` IP).
3. `VibeBuddyApp` scans the QR, and `ConnectionStore` encodes the full payload into **iOS `UserDefaults`** before connecting.
4. `GET /snapshot` and the WebSocket `/ws` upgrade require the bearer token in `Authorization: Bearer <token>`; without it, `/snapshot` returns `401` and `/ws` refuses the upgrade. `GET /health` is open (liveness only). `POST /hook`, `/approval`, and `/terminal` also require the same token (header or `?token=`, **ADR-0009**).
5. On initial connection and reconnect (phone woke, WiFi changed), the app opens `/ws` directly. After the WebSocket is established, the server immediately pushes the current snapshot and then subsequent updates; the current iOS client does not pre-fetch `GET /snapshot`.

## Wire Protocol

**Daemon → clients (LAN):**

| Endpoint | Auth | Purpose |
|---|---|---|
| `GET /health` | none | liveness probe for the connection screen |
| `GET /snapshot` | bearer token | full `Snapshot` JSON for explicit REST callers; not used by the current iOS reconnect path |
| `GET /ws` | bearer token | WebSocket stream; current `Snapshot` immediately after upgrade, then subsequent `ServerEvent` frames |
| `POST /notified` | bearer token | the phone's receipt for cues it posted itself (`NotifiedPayload`); the Mac's push for those stands down (**ADR-0012**) |

**Hooks → daemon (bearer token; query token allowed per ADR-0009):**

| Endpoint | Purpose |
|---|---|
| `POST /hook` | raw Claude Code / Codex hook payload (stdin JSON forwarded by the hook command) |
| `POST /approval` | opt-in blocking phone-approval gate |
| `POST /terminal` | jump-to-terminal capture |

Hook command (the installer records the canonical forwarder's absolute path in Claude Code `settings.json`; shown repository-relative here):
`hooks/vibebuddy-forward.sh claude`

The forwarder reads `VIBEBUDDY_TOKEN` or the token file selected by `VIBEBUDDY_TOKEN_FILE` (default: `$HOME/Library/Application Support/vibebuddy/token`) on every invocation, sends the shared install token as `Authorization: Bearer <token>`, and remains fail-open if delivery fails.

## Key Architectural Decisions

1. **Single shared package (VibeBuddyKit).** Models + `Codable` live once; the two apps can't drift on the wire format. *Trade-off*: both Xcode apps take a local-package dependency (fine in a monorepo).
2. **Mac side is a SwiftUI `MenuBarExtra` app (R1)**, not a headless CLI. Gives a Mac-side glance and a home for launch-at-login, port config, and the pairing QR; matches `eul` / open-vibe-island. The hook-intake, reducer, and WebSocket server are embedded in the Mac product.
3. **QR pairing + bearer token (R2).** The phone scans a QR instead of typing an IP; the token gives light LAN auth and is reused unchanged when the host becomes a Tailscale IP. The Mac stores it in an owner-only file; iOS stores the full pairing payload in `UserDefaults`.
4. **Status delivery is bounded and fail-open; the daemon is not read-only.** Claude status hooks run asynchronously and stay off the agent's critical path. Codex and Grok currently invoke status hooks synchronously, but the forwarder caps local HTTP delivery at one second for Codex and three seconds for Grok, so a missing or wedged daemon can delay them only briefly. Remote approval is an opt-in blocking gate. Hook routes share the install bearer token (**ADR-0009**).
5. **Source-agnostic sessions.** `agent: AgentKind` on every session; Claude Code and Codex are adapters normalizing their payloads into one `AgentSession`. Codex is additive.
6. **Server library.** The current server is implemented directly with **Hummingbird 2** and HummingbirdWebSocket. There is no `NWListener` backend or `Server` protocol layer in the current implementation.
7. **Transport is config, not code.** `host:port` + token are data (delivered by QR), so LAN→Tailscale is a value swap.
8. **One banner per cue, decided by the phone (ADR-0012).** The phone's local notification and the Mac's APNs push share one identifier, but iOS keeps them as two banners. The phone reports what it posted (`POST /notified`); the Mac holds a push for up to 3 s while a `/ws` subscriber exists and drops it on that receipt, otherwise sends as before. In the other order the phone declines a waiting cue whose push is already in Notification Center. Both rules fail toward "push": nothing can remove the only alert. Measured on device: iOS tears the socket down about 2 s after the app leaves the foreground, and a backgrounded app can reconnect on its own tens of seconds later — the source of the original duplicate.

## Testing Seams (for TDD / to-spec)

- **Reducer** (`[HookEvent] → [AgentSession]`): pure function, highest-value unit tests — feed recorded hook sequences, assert statuses. No I/O.
- **TranscriptReader** (`Data → (model, tokens, summary)`): pure parse over fixture JSONL tails.
- **VibeBuddyKit decoding**: round-trip `Snapshot` / `ServerEvent` / `PairingPayload` encode→decode.
- **App ConnectionStore**: protocol-based transport (per `networking-layer`), so a fake transport feeds canned `ServerEvent`s without a live daemon.

Prefer these existing seams; the reducer is the highest one and where most behavior lives.
