# vibebuddy

See the live status of your Claude Code / Codex sessions on your iPhone, grouped
into **需回应 / 进行中 / 已完成**, so you know which agent needs you, which is
still working, and which is done.

Borrows the detection concept from `m5-paper-buddy` and `open-vibe-island`,
re-pointed at a phone over your own network. All-Swift. See `docs/planning/`.

## Architecture

```
Claude Code / Codex ──hooks──▶ VibeBuddyMac (macOS menu-bar app)
                               • reduce hooks → needsResponse / working / done
                               • parse JSONL transcript → model / tokens / summary
                               • HTTP + token over LAN  (GET /snapshot, /health)
                                       │  scan QR to pair (host:port + token)
                                       ▼
                               VibeBuddyApp (iPhone, SwiftUI)
                               • 3-bucket dashboard, polls /snapshot
                               • local notification on new needsResponse
            shared VibeBuddyKit (one Codable wire model)
```

## Layout

| Path | What |
|------|------|
| `VibeBuddyKit/` | Shared Codable wire model (SwiftPM) |
| `VibeBuddyMac/` | macOS core lib + `vibebuddyd` headless CLI (SwiftPM) |
| `VibeBuddyMacApp/` | macOS menu-bar app (xcodegen) — Keychain token, launch-at-login |
| `VibeBuddyApp/` | iOS app (xcodegen — run `xcodegen generate` first) |
| `docs/planning/` | overview, prd, architecture, roadmap, prior-art |

## Run it

**Mac side (menu-bar app):**
```bash
cd VibeBuddyMacApp && xcodegen generate
open VibeBuddyMacApp.xcodeproj   # build & run (⌘R)
```
A menu-bar-only app: live counts, "Pair a phone" QR, and a launch-at-login
toggle; the LAN token lives in the Keychain. (`vibebuddyd` in `VibeBuddyMac/`
remains as a headless CLI: `swift run vibebuddyd`.)

**iOS app (Simulator):**
```bash
cd VibeBuddyApp && xcodegen generate
open VibeBuddyApp.xcodeproj   # run on a Simulator/device
```
Pair by scanning the QR, or enter host/port/token manually. (Simulator: use
`127.0.0.1` and the token from `~/Library/Application Support/vibebuddy/token`.)

**Hooks (to feed real Claude Code):**
```bash
python3 hooks/install-claude-hooks.py --dry-run    # preview the change
python3 hooks/install-claude-hooks.py --install    # back up + install
python3 hooks/install-claude-hooks.py --uninstall  # revert
```
Installs fail-open `curl` POSTs to `http://127.0.0.1:9876/hook` for the 6
lifecycle events. Then run the menu-bar app (or `vibebuddyd`) and your real
Claude Code sessions appear on the phone.

## Tests

```bash
cd VibeBuddyKit && swift test     # 12
cd VibeBuddyMac && swift test     # 40
```

## Status

v1 core complete & verified end-to-end in the Simulator. Open: Claude Code hook
installer, `/ws` WebSocket push, Codex adapter + Dynamic Island (v1.5),
launch-at-login + Keychain. See `docs/planning/roadmap.md`.
