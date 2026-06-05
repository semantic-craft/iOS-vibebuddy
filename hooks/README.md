# Feeding agents into vibebuddy

Every wire-up is a fail-open POST to the local daemon — if no daemon is running it
fails instantly and never affects the agent.

## Universal installer (all CLIs at once)

```bash
python3 hooks/install-agent-hooks.py --dry-run    # detect + preview
python3 hooks/install-agent-hooks.py --install    # wire every detected CLI
python3 hooks/install-agent-hooks.py --uninstall  # revert every detected CLI
```

Detects which CLIs are configured (by their config dir/file — no PATH scanning)
and delegates to the per-CLI installer for each: **Claude, Qwen, Grok,
Antigravity, Kimi, OpenCode**. Idempotent (re-run = no-op), reversible (removes
exactly what it added; pre-existing user hooks untouched), each per-CLI installer
backs up before writing. **Codex** is detected but not auto-managed (its single
`notify` slot is user-owned — see below). The per-CLI installers below are still
available if you want to wire one CLI at a time.

Claude-shape CLIs (Claude, Qwen, Kimi) need no daemon decoder; Codex / Grok /
Antigravity are decoded per-source inside the daemon. (Note: Antigravity `agy`
1.0.5 *loads* its hooks but does not yet *execute* them — an agy-side bug; the
wiring is ready for when an agy update fixes it.)

## Claude Code

```bash
python3 hooks/install-claude-hooks.py --dry-run    # preview
python3 hooks/install-claude-hooks.py --install    # back up + install
python3 hooks/install-claude-hooks.py --uninstall  # revert
```
Installs the 7 lifecycle hooks (SessionStart / UserPromptSubmit / PreToolUse /
PostToolUse / Notification / Stop / SessionEnd) into `~/.claude/settings.json`.
Gives the full needsResponse / working / done state machine, and `SessionEnd`
removes a session from the dashboard when you exit / `/clear` / log out — so an
idle "needs you" prompt never outlives the session.

## Codex

Codex calls a `notify` program with the event JSON as an argument. Point it at
the forwarder, which POSTs to `…/hook?agent=codex`:

`~/.codex/config.toml`:
```toml
notify = ["/Users/example/Projects/iOS-vibebuddy/hooks/codex-notify.sh"]
```
Codex currently emits `agent-turn-complete`, which shows the session as **done**
(with the last assistant message). If your Codex build also supports the richer
hook events (SessionStart/Stop/…), install them pointing at `…/hook?agent=codex`
and they flow through the same state machine.

**Already have a Codex `notify`** (e.g. Codex Computer Use)? Codex allows only one
notify program, so use the chaining wrapper instead — it calls your existing
notify *and* forwards to vibebuddy:
```toml
notify = ["/Users/example/Projects/iOS-vibebuddy/hooks/codex-notify-chain.sh"]
```
(Edit the `ORIG=` path inside the script to your existing notify program.)


## Daemon

The hooks target `http://127.0.0.1:9876/hook` (override with `VIBEBUDDY_PORT`).
Run the menu-bar app (`swift run VibeBuddyMenuBar`) or `vibebuddyd` so something
is listening.

## Remote approval (opt-in)

```bash
python3 hooks/install-claude-hooks.py --approval   # add the blocking PreToolUse approval hook
python3 hooks/install-claude-hooks.py --uninstall  # removes it too
```
Commands not in your `permissions.allow` are sent to the phone to approve/deny.
On timeout/unreachable, Claude proceeds with its normal behaviour. Useful only if
your Mac actually prompts (prompting mode); auto-mode users gain nothing.

## Terminal capture (jump-back)

`capture-terminal.sh` is installed automatically as a second SessionStart hook by
`--install` (and removed by `--uninstall`). On each new Claude Code session it
POSTs the session's `TERM_PROGRAM`, `TTY`, `TMUX`, and `TMUX_PANE` to
`http://127.0.0.1:${VIBEBUDDY_PORT:-9876}/terminal`. The Mac app stores this as
`AgentSession.terminalRef` and uses it to focus the right terminal window when you
press **Jump to terminal** in the Dashboard.
