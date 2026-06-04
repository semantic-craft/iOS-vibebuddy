# iOS buddy + rich approval + context bar — Implementation Plan

> Execute task-by-task. TDD for pure logic (write failing test → watch fail → minimal code → green). `- [ ]` = step.

**Goal:** iOS status buddy + rich approval cards + per-session context bar.
**Spec:** `docs/superpowers/specs/2026-06-04-ios-buddy-rich-approval-design.md`
**Order:** shared wire model → Mac pure logic (TDD) → daemon wiring → iOS UI → verify.

---

## Phase 0 — Shared wire model (VibeBuddyKit) — both apps depend on it
- [ ] **0.1** `Models.swift` — extend `PendingApproval` with optional `command`, `filePath`, `oldText`, `newText` (keep `commandPreview`). All optional → Codable-backward-compatible.
- [ ] **0.2** `Models.swift` — extend `AgentSession` with optional `contextTokens: Int?`, `contextWindow: Int?`.
- [ ] **0.3** `BuddyState.swift` (Kit) — `enum BuddyState { needsResponse, working, done, sleeping }` + `static func from(_ g: SessionGroups) -> BuddyState` (priority: needsResponse → working → done → sleeping).
- [ ] **0.4** TEST (Kit): `BuddyStateTests` — each priority branch (needsResponse wins over working, etc.; empty → sleeping). Run `swift test` in VibeBuddyKit → green.

## Phase 1 — Mac Core pure logic (VibeBuddyMacCore, TDD)
- [ ] **1.1** TEST first: `ApprovalDetailsTests` — `ApprovalDetails.from(toolName:, toolInput: [String:Any]) -> (command,filePath,oldText,newText, preview)` for Bash (command), Edit (filePath+old+new), Write (filePath+new), Read (filePath). Watch fail.
- [ ] **1.2** `ApprovalDetails.swift` — pure extractor; read Edit keys defensively (`old_string`/`new_string` **and** `old_text`/`new_text`). Cap each field to 6 KB. Green.
- [ ] **1.3** TEST first: `TranscriptReader` `contextTokens` — given a tail with `usage:{input_tokens,cache_read_input_tokens,cache_creation_input_tokens}`, `TranscriptInfo.contextTokens == input+cache_read+cache_creation`. Watch fail.
- [ ] **1.4** `TranscriptReader.swift` — add `contextTokens` to `TranscriptInfo`; compute in `parse`. Green (existing `tokens` unchanged).
- [ ] **1.5** `SessionReducer.swift` — `enrich` copies `contextTokens`; derive `contextWindow` from `model` (200_000 default for current Claude/Codex models). TEST: enrich sets both. Green.
- [ ] **1.6** Run full `VibeBuddyMac` `swift test` → all green (104 + new).

## Phase 2 — Mac daemon wiring
- [ ] **2.1** VERIFY (live): capture one real PreToolUse payload for `Edit` to confirm the exact `tool_input` keys; adjust `ApprovalDetails` if needed.
- [ ] **2.2** `VibeBuddyServer.swift` `/approval` — build `PendingApproval` via `ApprovalDetails.from(...)` (fill `command/filePath/oldText/newText` + existing `commandPreview`). TEST: the `/approval` route surfaces the rich fields in the broadcast snapshot (extend existing approval-route test). Green.
- [ ] **2.3** Build the daemon/app, deploy Mac (`xcodegen` + `xcodebuild` Release + `ditto` + relaunch).

## Phase 3 — iOS UI (VibeBuddyApp)
- [ ] **3.1** `BuddyView.swift` (new) — emoji + animated color ring from `BuddyState`: 🔔 orange bounce / 🤖 blue pulse / ✅ green / 😴 grey. One-line status text.
- [ ] **3.2** `DashboardView.swift` — header: `BuddyView(state: BuddyState.from(store.groups))` above the list.
- [ ] **3.3** `DashboardView.swift`/`SessionRow` — rich approval card by `tool`: Bash → mono command block; Edit → path + old→new diff (red/green); Write → path + new preview; Read → path. Keep 拒绝/批准.
- [ ] **3.4** `SessionRow` — context bar: `ProgressView(value: contextTokens/contextWindow)` + "128k / 200k" label; hidden when `contextTokens == nil`.
- [ ] **3.5** iOS build (`xcodegen` + `xcodebuild` iOS simulator) → succeeds.

## Phase 4 — Verify + commit
- [ ] **4.1** VibeBuddyKit + VibeBuddyMac tests green; Mac app + iOS app build.
- [ ] **4.2** (USER) device/sim smoke: buddy reflects aggregate state; trigger an approval → rich card shows full command/diff; context bar shows.
- [ ] **4.3** Commit (Conventional Commits) after user OK.

## App Store prep — separate, when user is ready
- [ ] **A.1** Add `NSLocalNetworkUsageDescription` to the iOS app (project.yml / Info.plist).
- [ ] **A.2** Hand user the step-by-step submission checklist (enrol $99/yr → App Store Connect record → icons/screenshots/privacy labels → archive+upload → submit).
