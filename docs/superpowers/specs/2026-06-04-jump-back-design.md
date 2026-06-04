# Jump-back to terminal — design

**Date:** 2026-06-04
**Status:** Approved (design locked: Ghostty + tmux; triggerable from Mac dashboard/glance AND the iOS app)
**Sub-project of the Mac-app parity epic.** Replaces the stubbed "Jump to terminal" buttons in the dashboard and glance.

## Goal
Click "Jump to terminal" (in the Mac dashboard, the glance, or the iOS app) and the Mac brings the *exact* terminal pane that session is running in to the front. For this user that's a **tmux pane inside a Ghostty window**, so a jump = select the tmux pane **and** activate Ghostty.

## The crux: knowing where a session runs
The daemon doesn't know a session's terminal. So a hook (running inside that tmux pane) captures terminal-identifying info and reports it, keyed by `session_id`.

## In scope
- **Wire model** (`VibeBuddyKit`): `TerminalRef { termProgram: String, tty: String?, tmux: String?, tmuxPane: String? }` + `AgentSession.terminalRef: TerminalRef?` (optional, additive). Present → clients enable the jump button.
- **Capture hook** `hooks/capture-terminal.sh` (installed for `SessionStart`): reads the hook JSON on stdin, extracts `session_id` (sed), and POSTs `{session_id, term_program: $TERM_PROGRAM, tty: $(ps -o tty= -p $$), tmux: $TMUX, tmux_pane: $TMUX_PANE}` to `POST /terminal`. Fail-open (`|| true`).
- **Daemon endpoints:** `POST /terminal` (localhost, no token — like `/hook`) stores the `TerminalRef` on the session + broadcasts. `POST /jump` (token-gated) `{sessionId}` → runs the jumper for that session's `terminalRef`.
- **`TerminalJumper`** (`VibeBuddyMacCore`): pure `commands(for: TerminalRef) -> [[String]]` (TDD'd) + `jump(_ ref:)` that runs them via `Process` (no AppKit — uses `/usr/bin/open -a` to activate). For a tmux ref: parse the socket from `$TMUX` (substring before the first `,`), then
  `tmux -S <socket> switch-client -t <pane>` ; `select-window -t <pane>` ; `select-pane -t <pane>`,
  then activate the terminal app from `term_program` (`ghostty` → `open -a Ghostty`; map iTerm.app/Apple_Terminal/WezTerm too for free).
- **Store:** `terminalRef` per session (reducer set + store method, mirroring `pendingApproval`).
- **Triggers:** Mac dashboard + glance "Jump to terminal" buttons (enabled when `terminalRef != nil`) → `MenuBarModel.jump(session)` (calls `TerminalJumper` in-process). iOS `SessionRow` "跳回终端"/"Jump" button → `POST /jump` with the pairing token (extends the existing `DecisionClient` pattern).

## Out of scope (v1)
- Terminals other than Ghostty + tmux (the `term_program → app` map makes adding iTerm/Terminal/WezTerm cheap later, but only Ghostty+tmux is verified).
- Non-tmux Ghostty (no multiplexer): falls back to just activating Ghostty (best-effort).
- Per-window precision when multiple Ghostty windows exist (v1 activates the app; tmux handles the pane).

## Data flow
SessionStart → capture hook → `POST /terminal` → `terminalRef` stored on the session → dashboard/glance/iOS show an enabled jump button. Jump (Mac) → `MenuBarModel.jump` → `TerminalJumper.jump(ref)`; Jump (iOS) → `POST /jump` → daemon → `TerminalJumper.jump(ref)`. Either way the Mac's tmux selects the pane + Ghostty comes forward.

## Error handling
- No `terminalRef` for a session → jump button disabled / `/jump` is a no-op 200.
- `tmux`/`open` failures → logged, swallowed (best-effort; never crash). A stale pane id (pane closed) → tmux command fails harmlessly.
- `/jump` token-gated; `/terminal` localhost-only (like `/hook`).

## Testing
- **Unit (TDD):** `TerminalRef` Codable round-trip (Kit); `TerminalJumper.commands(for:)` builds the right tmux argv + socket parsing + `term_program→app` mapping (Core); reducer set-terminalRef; `/terminal` stores it and `/jump` is token-gated + invokes the jumper (in-process route tests).
- **Live (user, on Ghostty+tmux):** run a Claude session in a tmux pane in Ghostty, jump from the dashboard/glance/phone, confirm that exact pane comes to front. The precise tmux invocation (switch-client/select-window/select-pane target resolution) is verified here — adjust if tmux target rules need a tweak.

## Non-goals
Other terminals (deferred), window-level precision, jump history.
