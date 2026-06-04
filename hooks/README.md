# Feeding agents into vibebuddy

Both wire-ups are fail-open `curl` POSTs to the local daemon — if no daemon is
running they fail instantly and never affect the agent.

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
