# vibebuddy iOS — status buddy + rich approval cards + context-usage bar (design)

**Date:** 2026-06-04 · **Status:** drafted, pending user review
**Goal:** Make the iOS companion genuinely useful and App-Store-viable (Apple 4.2 "minimum functionality") by adding (1) an ambient status **buddy**, (2) **rich approval cards** (full command / file diff / preview, not just a 120-char string), and (3) a per-session **context-window usage bar**. All three are verified feasible on the current hook architecture.

## Verified-out-of-scope
- **Remote-answering `AskUserQuestion`**: Claude Code fires **no hook** for `AskUserQuestion` and exposes no SDK/MCP way to answer it programmatically (verified via claude-code-guide + transcript). The only path is typing the answer into the terminal — that belongs to the future **terminal-injection** project (which depends on the unfinished jump-back pane targeting). Not in this slice.
- iOS UI language stays as-is (Chinese) to match the existing app; English unification is a separate decision.

## Feature 1 — Status buddy (the "display effect")
A single ambient companion at the top of the iOS dashboard reflecting **aggregate** state (like m5-paper-buddy's one cat). Style chosen by user: **emoji + animated color ring**.

State mapping (priority order):
- any `needsResponse` / `pendingApproval` → 🔔 in an **orange** ring, bouncing — "needs you"
- else any `working` → 🤖 in a **blue** ring, pulsing — "working…"
- else any `done` → ✅ in a **green** ring — "all done"
- else (no sessions) → 😴 in a **grey** ring — "sleeping"

Pure SwiftUI; no new data. New file `BuddyView.swift`; a small pure helper `BuddyState` (enum + `from(SessionGroups)`) is unit-tested.

## Feature 2 — Rich approval cards
The daemon already receives the full `tool_input` at `POST /approval`; today it forwards only `commandPreview` (120 chars). Enrich the wire model and the card.

**Wire model (VibeBuddyKit/Models.swift) — extend `PendingApproval`** (all new fields optional, Codable-backward-compatible):
- `command: String?` — full Bash command (Bash)
- `filePath: String?` — target path (Edit/Write/Read)
- `oldText: String?`, `newText: String?` — for Edit/Write (a diff / new-content preview)
- keep `commandPreview` (used by notifications / fallback)
Each text field capped (~6 KB) on the Mac so snapshots stay small.

**Mac (`VibeBuddyServer` `/approval`):** populate the new fields from `tool_input` when building `PendingApproval`. Read keys **defensively** — verify the real Edit payload keys (`old_string`/`new_string` vs `old_text`/`new_text`) against a live PreToolUse payload before finalizing. No hook-script change.

**iOS (`DashboardView`/`SessionRow`):** when `pendingApproval != nil`, render a card by `tool`:
- Bash → monospaced command block (scrollable, full command)
- Edit → file path + a simple old→new diff view (red/green lines)
- Write → file path + new-content preview
- Read → file path
Keep the existing 拒绝/批准 buttons (`decide(approval.id, approve:)`).

## Feature 3 — Context-window usage bar
**Transcript (`TranscriptReader`):** the last assistant `message.usage` has `input_tokens`, `cache_read_input_tokens`, `cache_creation_input_tokens`. The prompt actually sent ≈ their sum ≈ context consumed. Add `contextTokens` to `TranscriptInfo` = `input + cache_read + cache_creation` (pure; unit-tested). Existing `tokens` (input+output, the turn cost) is unchanged.

**Wire model:** add `AgentSession.contextTokens: Int?` and `contextWindow: Int?` (by model; default 200_000). `reducer.enrich` copies `contextTokens` from `TranscriptInfo`; `contextWindow` derived from `model` (200k for current Claude models).

**iOS:** per-session thin bar `contextTokens / contextWindow` with a "128k / 200k" label; hidden when `contextTokens == nil`.

## Testing (TDD for pure logic)
- `BuddyState.from(SessionGroups)` mapping (each priority branch).
- `TranscriptReader` `contextTokens` from a `usage` object (input+cache_read+cache_creation).
- Rich-preview extraction: a pure helper that turns `tool_name`+`tool_input` JSON into the `PendingApproval` rich fields (Bash/Edit/Write/Read), tested against sample payloads.
- AppKit/SwiftUI views + the live `/approval` enrichment verified by build + device smoke test.

## File plan
- VibeBuddyKit: `Models.swift` (extend `PendingApproval`, `AgentSession`).
- VibeBuddyMacCore: `TranscriptReader.swift` (+contextTokens), `SessionReducer.swift` (enrich/contextWindow), a new pure `ApprovalDetails.swift` (tool_input → rich fields) + `VibeBuddyServer.swift` (use it), tests under `VibeBuddyMacCoreTests`.
- VibeBuddyApp: `BuddyView.swift` (new), `DashboardView.swift` (header buddy + rich card + usage bar), a small `BuddyState` (in Kit or app + test).

## App Store submission (separate from this build — user-only steps)
1. Enrol in Apple Developer Program ($99/yr) — only a free-tier "Apple Development" cert exists today.
2. Add `NSLocalNetworkUsageDescription` to the iOS app (has `NSAllowsLocalNetworking` ATS exception but not the privacy usage string).
3. App Store Connect record, icons, screenshots, privacy labels, archive + upload, submit. (I can prep #2 + a checklist; I cannot log in/pay/submit.)
