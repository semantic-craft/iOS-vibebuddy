# Feeding agents into vibebuddy

Both wire-ups are fail-open `curl` POSTs to the local daemon — if no daemon is
running they fail instantly and never affect the agent.

## Claude Code

```bash
python3 hooks/install-claude-hooks.py --dry-run    # preview
python3 hooks/install-claude-hooks.py --install    # back up + install
python3 hooks/install-claude-hooks.py --uninstall  # revert
```
Installs the 6 lifecycle hooks (SessionStart / UserPromptSubmit / PreToolUse /
PostToolUse / Notification / Stop) into `~/.claude/settings.json`. Gives the full
needsResponse / working / done state machine.

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

## Daemon

The hooks target `http://127.0.0.1:9876/hook` (override with `VIBEBUDDY_PORT`).
Run the menu-bar app (`swift run VibeBuddyMenuBar`) or `vibebuddyd` so something
is listening.
