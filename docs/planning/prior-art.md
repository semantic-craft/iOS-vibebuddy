# vibebuddy — Prior Art & What to Borrow

**Last Updated**: 2026-06-03
**Method**: every GitHub project below was verified live with `gh` (existence, stars, license, last push). App Store apps are closed-source and were not code-verifiable. Claims I could not verify are marked as such — per the project rule to separate verified facts from candidates.

## ⚠️ License caveat (read first)

The three closest open-source analogs are all **`no-license` on GitHub = "all rights reserved."** Legally you may *read and learn from* them, but you may **not copy their code** into vibebuddy without permission. So everything below is **borrow the architecture/concepts, write our own Swift**. This also matches the original plan (we always intended a clean Swift re-implementation).

## Verified open-source references

| Project | Verified | Borrow | License |
|---|---|---|---|
| **onikan27/claude-code-monitor** | ✅ ⭐235, active 2026-01 | The whole shape: hook-into-`settings.json` + WebSocket + **QR pairing** + 3-state model. Closest prior art. | no-license (study only) |
| **Maciek-roboblog/Claude-Code-Usage-Monitor** | ✅ ⭐8.1k | Context-window % and quota/limit **prediction & warnings** (a v1.5 feature on top of our `tokens`). | no-license (study only) |
| **gao-sun/eul** | ✅ ⭐9.9k, stale since 2024 | How to structure a **SwiftUI macOS monitoring app** (metrics collection, refresh, status UI). | no-license (study only) |
| op7418/m5-paper-buddy | ✅ (planning ref) | Transcript-tail JSONL parsing; RUNNING/WAITING sets; fail-open hook curl. | — |
| Octane0411/open-vibe-island | ✅ (planning ref) | Source-agnostic `SessionState` reducer across 10+ agents; macOS menubar/notch UX. | GPL-3.0 (study; copyleft) |

## Closest analog deep-dive: onikan27/claude-code-monitor (verified)

Node/TypeScript, serverless, no external data transmission. Confirmed details:

- **Collection**: registers hooks into `~/.claude/settings.json`; file-based state, no API server. (Same approach we chose.)
- **Transport**: **WebSocket** for real-time updates; default port 3456 with auto-fallback. (Same as ours.)
- **States per session**: **● Running / ◐ Waiting / ✓ Done** — essentially our `working / needsResponse / done`. Independent confirmation our 3-bucket model is right.
- **QR pairing + token**: press `h` → shows a QR encoding the URL **with an embedded auth token** ("treat it like a password"). Phone scans → connected. No manual IP typing.
- **Remote**: responds to permission prompts via an on-screen **D-pad + Enter + screen capture** of the terminal. (This is the v2 territory we deferred — and a hint that our *structured* hook-based approval would be cleaner than screen-scraping.)
- **Tailscale**: a `-t` flag makes the QR encode the Tailscale `100.x` IP (WireGuard-encrypted). Confirms our "transport is config, not code" decision — Tailscale is just a different value in the same QR.

## Could-not-verify / closed-source (do not treat as fact)

- **AgentsRoom**, **Control: AI Agent Remote** — described as App Store apps (closed source). Useful only as **UX inspiration** (color-coded Thinking/Coding/Done/Blocked; LAN-only; streaming diffs). No code to borrow.
- **agtrace**, **RepoBar**, **KyanBar**, **"Peek"** — `gh` search returned **no matching repo** under these names. Unverified; not relied upon. (Generic menubar/dashboard ideas are well covered by `eul` and `open-vibe-island` anyway.)

## Borrow-map → impact on our plan

**1. Strong validation (no change needed):**
- 3-state model (Running/Waiting/Done) is independently the industry pattern. ✅
- Hook-into-`settings.json` + WebSocket + local-first is the converged design. ✅
- "Transport = config" (LAN IP today, Tailscale `100.x` later via the same channel). ✅

**2. Two concrete refinements worth adopting (decisions for the user):**
- **R1 — Mac side as a SwiftUI `MenuBarExtra` app** (not a headless CLI). Gives a Mac-side glance, a natural home for pairing/launch-at-login/port config, and matches `eul` / `open-vibe-island`. Still all-Swift, still embeds the hook-intake + reducer + WebSocket server.
- **R2 — QR-code pairing with an embedded token** as the connect UX. The Mac menubar shows a QR encoding `host:port` (+ a bearer token); the phone scans it instead of typing an IP. Near-free, removes manual config, and the token gives light LAN auth — softening the earlier "no auth in v1" to "trivial auth in v1." Same QR later encodes the Tailscale IP.

**3. Deferred features these projects confirm are worth a later look:**
- Context-window % + quota/limit prediction (from Claude-Code-Usage-Monitor) → v1.5 on top of `tokens`.
- Structured remote approval (cleaner than onikan27's screen-capture+D-pad) → v2.
