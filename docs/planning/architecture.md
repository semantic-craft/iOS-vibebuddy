# vibebuddy — Architecture

**Last Updated**: 2026-06-03

## Components

```
Mac
  Claude Code / Codex
      │  lifecycle hooks POST JSON  (curl, "fail open")
      ▼
  VibeBuddyMac  (SwiftUI MenuBarExtra app, depends on VibeBuddyKit)
      • MenuBarExtra UI   → status glance, port config, launch-at-login, "Show pairing QR"
      • POST /hook        ← localhost only, hook intake (no token)
      • Reducer           → derive per-session status (needsResponse/working/done)
      • TranscriptReader  → tail JSONL for model, tokens, last assistant text
      • Broadcaster       → push ServerEvent to WS clients
      • GET /snapshot, GET /ws   ← bound to 0.0.0.0:PORT (LAN), bearer-token gated
      • GET /health              ← unauthenticated liveness probe
      │
      │  LAN WebSocket + REST, bearer token  (later: Tailscale 100.x via same channel)
      ▼
iPhone
  VibeBuddyApp  (SwiftUI, depends on VibeBuddyKit)
      • Pairing      → scan QR → {host, port, token} → Keychain
      • Connection store (reconnect, snapshot-on-reconnect)
      • Dashboard (3 sections) + local notifications
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
    public var token: String         // bearer token, stored in Keychain on the phone
}
```

## State Machine (hook event → status)

We register these Claude Code hooks and reduce them. This is **non-blocking** (unlike m5-paper-buddy, which blocked `PreToolUse` to relay device approvals) because v1 is read-only.

| Hook event | Effect on session |
|---|---|
| `SessionStart` | upsert session, `status = working`, set project/branch/cwd |
| `UserPromptSubmit` | `status = working`, `statusSince = now` |
| `PreToolUse` | stay `working`; record active tool name for the "working" detail |
| `PostToolUse` | stay `working`; clear active tool |
| **`Notification`** | **`status = needsResponse`**; derive `waitKind` from the message ("needs your permission" → `.permission`; "waiting for your input" → `.question`); `summary` = message |
| `Stop` | `status = done` (unless a later event already moved it) |

On every event the daemon also refreshes derived metadata via **TranscriptReader**: seek to the JSONL tail (read last ~128 KB), scan backward for the latest `assistant` message → `model`, `usage.input_tokens + output_tokens` → `tokens`, and collapsed text → `summary` (when not overridden by a permission/question). Git project/branch read from `cwd` with a short TTL cache. (Concepts from `m5-paper-buddy`'s `claude_code_bridge.py`.)

**Why `Notification` not `PreToolUse`-counting:** `PreToolUse` fires for every tool, including auto-approved ones, so it can't by itself mean "needs you." Claude Code's `Notification` hook is purpose-built to fire when Claude wants the user's attention — the correct, low-false-positive signal for `needsResponse`. (Independently confirmed by onikan27/claude-code-monitor's Running/Waiting/Done model.)

## Connection & Pairing

1. `VibeBuddyMac` generates a random `token` on first run (kept in the Mac Keychain) and binds the server to `0.0.0.0:PORT`.
2. The menu bar's **"Show pairing QR"** renders a QR encoding `PairingPayload { host, port, token }` (host = current LAN IP; later a Tailscale `100.x` IP).
3. `VibeBuddyApp` scans the QR, stores the payload in the **iOS Keychain**, then connects.
4. Every `GET /snapshot` and `GET /ws` requires the bearer token (`Authorization: Bearer <token>`); requests without it get `401`. `GET /health` is open (liveness only). `POST /hook` is localhost-only and unauthenticated.
5. On reconnect (phone woke, WiFi changed) the app re-fetches `GET /snapshot` to resync, then resumes the `/ws` stream.

## Wire Protocol

**Daemon → clients (LAN):**

| Endpoint | Auth | Purpose |
|---|---|---|
| `GET /health` | none | liveness probe for the connection screen |
| `GET /snapshot` | bearer token | full `Snapshot` JSON — initial load and after reconnect |
| `GET /ws` | bearer token | WebSocket stream of `ServerEvent` frames |

**Hooks → daemon (localhost only, no token):**

| Endpoint | Purpose |
|---|---|
| `POST /hook` | raw Claude Code / Codex hook payload (stdin JSON forwarded by the hook command) |

Hook command (installed into Claude Code `settings.json`), fail-open like m5:
`curl -sS --max-time 3 -X POST --data-binary @- http://127.0.0.1:9876/hook 2>/dev/null || true`

## Key Architectural Decisions

1. **Single shared package (VibeBuddyKit).** Models + `Codable` live once; the two apps can't drift on the wire format. *Trade-off*: both Xcode apps take a local-package dependency (fine in a monorepo).
2. **Mac side is a SwiftUI `MenuBarExtra` app (R1)**, not a headless CLI. Gives a Mac-side glance and a home for launch-at-login, port config, and the pairing QR; matches `eul` / open-vibe-island. The hook-intake + reducer + WebSocket server are embedded behind a `Server` protocol.
3. **QR pairing + bearer token (R2).** The phone scans a QR instead of typing an IP; the token gives light LAN auth and is reused unchanged when the host becomes a Tailscale IP. Tokens live in Keychain on both sides.
4. **Non-blocking, read-only daemon.** Hooks return immediately; the daemon only observes — no blocking/timeout machinery, Claude Code stays fully responsive. Revisited if remote control (v2) is added.
5. **Source-agnostic sessions.** `agent: AgentKind` on every session; Claude Code and Codex are adapters normalizing their payloads into one `AgentSession`. Codex is additive.
6. **Server library (Phase B decision).** Lean candidates: **Hummingbird 2** (small, async/await, first-class WS) or raw **Network.framework** `NWListener` (zero deps). Isolated behind the `Server` protocol so it's swappable.
7. **Transport is config, not code.** `host:port` + token are data (delivered by QR), so LAN→Tailscale is a value swap.

## Testing Seams (for TDD / to-spec)

- **Reducer** (`[HookEvent] → [AgentSession]`): pure function, highest-value unit tests — feed recorded hook sequences, assert statuses. No I/O.
- **TranscriptReader** (`Data → (model, tokens, summary)`): pure parse over fixture JSONL tails.
- **VibeBuddyKit decoding**: round-trip `Snapshot` / `ServerEvent` / `PairingPayload` encode→decode.
- **App ConnectionStore**: protocol-based transport (per `networking-layer`), so a fake transport feeds canned `ServerEvent`s without a live daemon.

Prefer these existing seams; the reducer is the highest one and where most behavior lives.
