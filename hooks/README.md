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
and delegates to the per-CLI installer for each: **Claude, Codex, Qwen, Grok,
Antigravity, Kimi, OpenCode**. Idempotent (re-run = no-op), reversible (removes
exactly what it added; pre-existing user hooks untouched), each per-CLI installer
backs up before writing. Codex uses its first-class lifecycle hooks in
`~/.codex/hooks.json`; the separate `notify` command is never changed, so Codex
Computer Use or another notifier keeps working. The per-CLI installers below
remain available if you want to wire one CLI at a time.

Claude-shape CLIs (Claude, Qwen, Kimi) need no daemon decoder; Codex / Grok /
Antigravity are decoded per-source inside the daemon. (Note: Antigravity `agy`
1.0.5 *loads* its hooks but does not yet *execute* them — an agy-side bug; the
wiring is ready for when an agy update fixes it.)

## Claude Code and Claude Desktop

```bash
python3 hooks/install-claude-hooks.py --dry-run    # preview
python3 hooks/install-claude-hooks.py --install    # back up + install
python3 hooks/install-claude-hooks.py --uninstall  # revert
```
Installs the current high-signal lifecycle set into `~/.claude/settings.json`:
session/turn start and end, permission and elicitation waits, successful and
failed tools, subagents, compaction, normal stop, stop failure, model switches,
and working-directory changes. Claude Code uses the same hooks in the terminal,
IDE, and Desktop app. Status handlers use Claude's exec-form command plus
`async: true`; they never enter the agent's critical path. `PostModelSwitch`
updates the displayed model, `CwdChanged.new_cwd` updates the displayed project
without changing progress state, and `SessionEnd` removes the session when it
really closes.

## Codex

Codex sends lifecycle event JSON on stdin to commands registered in
`~/.codex/hooks.json`. The universal installer safely appends VibeBuddy groups
for all 12 events supported by the current Codex hook schema: SessionStart,
UserPromptSubmit, PreToolUse, PostToolUse, PermissionRequest, PreCompact,
PostCompact, SubagentStart, SubagentStop, Stop, Interrupt, and SessionEnd.
Existing hook groups are retained.

Released Codex builds currently skip command hooks carrying `async: true`, even
though the rolling documentation describes asynchronous handlers. VibeBuddy
therefore installs synchronous handlers with a three-second hook limit; the
forwarder uses a one-second local HTTP cap so a missing daemon cannot materially
delay the agent. `SessionEnd` is synchronous by design.

```bash
python3 hooks/install-codex-hooks.py --install
```

Codex requires explicit trust after `hooks.json` changes. Start a fresh Codex
session, run `/hooks`, review the VibeBuddy entries, and trust them. The installer
does not read or forge Codex's trust state.

### Codex Desktop

Codex Desktop does not execute the user's CLI `hooks.json`. VibeBuddy therefore
tails the local `~/.codex/sessions/**/rollout-*.jsonl` stream in addition to the
CLI hooks. `task_started`, tool records, `task_complete`, and `turn_aborted` feed
the same reducer, so desktop work appears without `/hooks` trust. On startup only
currently active desktop turns are restored; old completed rollouts are not
replayed into the dashboard.


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
