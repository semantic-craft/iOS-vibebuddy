# Multi-CLI hook setup

VibeBuddy is source-agnostic: any coding CLI that can run a command on its
lifecycle events can feed the Mac. The Mac tags each event with its source via
the `?agent=` query parameter (`AgentKind.fromSource`), so sessions render with
the right name/glyph. Adding a CLI never touches the wire model.

Supported sources (`AgentKind`): `claude`, `codex`, `qwen`, `kimi`,
`antigravity` (Gemini), `grok`, `opencode`, `copilot`. Unknown sources fall
back to Claude Code (the most common hook-compatible shape).

## The universal hook command

Every CLI runs the same fail-open forwarder on each lifecycle event; only the
`agent=` value changes:

```bash
curl -sS --max-time 3 -X POST --data-binary @- \
  "http://127.0.0.1:9876/hook?agent=<source>" 2>/dev/null || true
```

The CLI pipes its event JSON on stdin. VibeBuddy reads `hook_event_name`,
`session_id`, `cwd`, `tool_name`, `message`, and (for `PostToolUse`)
`tool_response.is_error` to drive status and the stuck cue. The events we use:
`SessionStart`, `UserPromptSubmit`, `PreToolUse`, `PostToolUse`, `Notification`,
`Stop`, `SessionEnd`.

## Per-CLI configuration

| CLI | source | config | hook style | status |
|-----|--------|--------|-----------|--------|
| Claude Code | `claude` | `~/.claude/settings.json` | JSON `hooks` array | ✅ tested |
| Codex | `codex` | `~/.codex/hooks.json` (`notify` untouched) | JSON `hooks` array | ✅ tested |
| OpenCode | `opencode` | `~/.config/opencode/` plugin | Claude-compatible hooks | ⚠️ template |
| Qwen Code | `qwen` | `~/.qwen/` | Claude-compatible hooks | ⚠️ template |
| Kimi | `kimi` | `~/.kimi/config.toml` | TOML hooks | ⚠️ template |
| Antigravity (Gemini) | `antigravity` | `~/.gemini/antigravity-cli/hooks.json` | JSON `command` hooks | blocked: `agy` 1.0.5 loads but skips execution |
| Grok Build | `grok` | `~/.grok/hooks/vibebuddy.json` | JSON `command` hooks (camelCase envelope) | ✅ tested (1.0.13) |
| GitHub Copilot | `copilot` | — | observe mode (no hooks) | ⚠️ partial |

✅ = wired and exercised. ⚠️ template = the source routing + display are done in
the app; the config snippet below needs validation against the installed CLI.
Antigravity's VibeBuddy decoder and source routing are ready, but the installed
`agy` 1.0.5 binary loads `hooks.json` without executing command hooks, even with
explicit `enabled: true`, `PreToolUse`, matcher `run_command`, and a trusted
workspace.

### Claude Code (`~/.claude/settings.json`)

```json
{
  "hooks": {
    "SessionStart":     [{ "matcher": "", "hooks": [{ "type": "command", "command": "curl -sS --max-time 3 -X POST --data-binary @- 'http://127.0.0.1:9876/hook?agent=claude' 2>/dev/null || true" }] }],
    "UserPromptSubmit": [{ "matcher": "", "hooks": [{ "type": "command", "command": "curl -sS --max-time 3 -X POST --data-binary @- 'http://127.0.0.1:9876/hook?agent=claude' 2>/dev/null || true" }] }],
    "PreToolUse":       [{ "matcher": "", "hooks": [{ "type": "command", "command": "curl -sS --max-time 3 -X POST --data-binary @- 'http://127.0.0.1:9876/hook?agent=claude' 2>/dev/null || true" }] }],
    "PostToolUse":      [{ "matcher": "", "hooks": [{ "type": "command", "command": "curl -sS --max-time 3 -X POST --data-binary @- 'http://127.0.0.1:9876/hook?agent=claude' 2>/dev/null || true" }] }],
    "Notification":     [{ "matcher": "", "hooks": [{ "type": "command", "command": "curl -sS --max-time 3 -X POST --data-binary @- 'http://127.0.0.1:9876/hook?agent=claude' 2>/dev/null || true" }] }],
    "Stop":             [{ "matcher": "", "hooks": [{ "type": "command", "command": "curl -sS --max-time 3 -X POST --data-binary @- 'http://127.0.0.1:9876/hook?agent=claude' 2>/dev/null || true" }] }],
    "SessionEnd":       [{ "matcher": "", "hooks": [{ "type": "command", "command": "curl -sS --max-time 3 -X POST --data-binary @- 'http://127.0.0.1:9876/hook?agent=claude' 2>/dev/null || true" }] }]
  }
}
```

Other hook-compatible CLIs (OpenCode, Qwen) follow the same shape with
`agent=<their source>`. Kimi/Codex use their TOML hook tables; Antigravity uses
a Gemini plugin that shells out to the same curl. Copilot has no hook surface
yet — it appears once a future watcher observes it.

### Grok Build (`~/.grok/hooks/vibebuddy.json`)

```bash
python3 hooks/install-grok-hooks.py --dry-run     # preview
python3 hooks/install-grok-hooks.py --install     # write ~/.grok/hooks/vibebuddy.json
python3 hooks/install-grok-hooks.py --approval    # + the blocking phone-approval gate
python3 hooks/install-grok-hooks.py --uninstall   # revert
```

Grok loads every `~/.grok/hooks/*.json` file, so vibebuddy owns its own file and
never edits the user's. Reload without restarting: `/hooks` → `r`. Grok's `http`
hooks refuse loopback (SSRF guard), so these are `command` hooks piping the event
JSON into `hooks/vibebuddy-forward.sh grok`.

Installed events (grok's config keys; the wire values are snake_case):

| Family | Events | What vibebuddy does with them |
|--------|--------|-------------------------------|
| lifecycle | `SessionStart`, `SessionEnd` | open the session (with `modelId` and `transcriptPath`), then drop it |
| turn | `UserPromptSubmit`, `Stop`, `StopFailure`, `StopCancelled` | working → done; `StopFailure` shows the session as stuck |
| tool | `PreToolUse`, `PostToolUse`, `PostToolUseFailure` | active tool and the stuck cue |
| attention | `Notification` | `permission_prompt` → needs-you; `idle_prompt` → the idle backstop |
| topology | `SubagentStart`, `SubagentStop` | child-agent rows under the parent session |

Grok-specific decoding rules (`GrokParser`):

- `Stop` fires a second time at teardown with `reason` `channel_closed`/`shutdown`.
  Only `end_turn` (or a missing reason) settles a turn; `SessionEnd` reports the rest.
- `StopCancelled` is dispatched off the command loop, so it can land *after* the
  next turn's `UserPromptSubmit`. Every event carries `promptId`, which the reducer
  keeps as `HookEvent.turnID` and uses to drop a report for a superseded turn.
- `Notification`'s `task_complete` means a **background** task finished, which can
  happen mid-turn, so it is not a turn end and is ignored.
- Everything that can fire inside a subagent's own session carries `subagentType`
  there and omits it in the main session; those events are dropped so a child never
  moves the parent's status. `SubagentStart` fires in the parent and `SubagentStop`
  in the child, both keyed by the same `subagentId`, so the child's row still completes.
- Grok also imports `~/.claude/settings.json` hooks via `[compat.claude]`. Those
  entries deliver the Claude shape without `?agent=grok` and currently fail fail-open
  with `required env var(s) not set: ${PPID}` — harmless noise, never relied on.

#### Remote approval (`--approval`)

`--approval` replaces the fire-and-forget `PreToolUse` group with a blocking
`hooks/approval-hook.sh grok` (`timeout: 30`, no matcher = every tool), which posts
to `/approval?agent=grok` and answers grok's gate.

**A phone decision is authoritative only when grok runs with
`[ui] permission_mode = "always-approve"`** (`permissionMode` reads
`bypassPermissions` on the wire). In grok's `default` mode a hook `allow` only means
"not blocked" — grok still shows its own TUI prompt afterwards, and that prompt has
no external answer channel. In that mode vibebuddy can still surface the wait (the
`permission_prompt` notification) and *deny*, but the approval must be tapped on the
Mac.

### Terminal capture (for jump-to-terminal)

Jump-to-terminal needs to know which terminal each session runs in. A second hook,
`hooks/capture-terminal.sh`, POSTs to `/terminal` at three levels of precision:
`{tmux, tmux_pane}` for the multiplexer pane, `{tty, iterm_session_id,
wezterm_pane, kitty_window_id, kitty_listen_on, ghostty_terminal_id}` for the
window/tab/split of one emulator, and `{term_program, host_bundle_id, host_pid,
cwd}` for the app. `host_bundle_id` is the bundle identifier of the nearest GUI
ancestor process, so a session inside an embedded terminal — the Claude desktop
app, Cursor, Zed, a JetBrains IDE — is still reachable even though it exports no
`TERM_PROGRAM` at all. Background-only ancestors (`LSBackgroundOnly` or
`LSUIElement` in their `Info.plist`) are stepped over, because such a bundle id
can never be activated: the Claude Code CLI is itself one of these wrapper
`.app`s, nested under the Claude desktop app that actually owns the window. Empty values are omitted, and the Mac reads an empty
string as absence. Run the script with `--print` to see what it would send. `install-claude-hooks.py`, `install-codex-hooks.py`, and
`install-grok-hooks.py` all wire it to **both `SessionStart` and
`UserPromptSubmit`**: SessionStart catches new sessions, and UserPromptSubmit
re-captures so a session that missed SessionStart — e.g. the hook was added while
the session was already open — **self-heals on its next prompt**. That re-capture
is not idempotent (it skips the Ghostty AppleScript probe, which only answers
while the surface is focused), so the Mac **merges** each ref into the stored one
field by field — a later capture updates what it saw and never erases what it
didn't see. Grok's event payload uses camelCase `sessionId` and spells its event
name `hookEventName`; the script reads the payload's `session_id` first, then
`sessionId`, and only then falls back to `$GROK_SESSION_ID` — every process grok
spawned inherits that variable, so it would otherwise mis-attribute a Claude
session started from a shell inside grok. A session with no captured terminal can't be jumped to
(the iOS button hides; the Mac button disables; a phone jump reports "no
terminal"), and a session captured only at app level reports `activatedApp` —
the right app comes forward but the user still finds the tab. Codex requires re-trusting hooks via `/hooks` after this change picks
up the new capture group, same as any other `hooks.json` edit; Grok requires
reloading hooks (`/hooks` → `r`, or a new session) before the new capture group
takes effect, and its `command` must carry an argument — grok resolves a quoted,
argument-less command as a literal path — so the capture hook is installed as
`"…/capture-terminal.sh" grok` (and `… claude` on the Claude side, whose hooks
grok imports through `[compat.claude]`).

### Reversibility

Every managed entry should carry a marker comment so it can be removed cleanly,
e.g. `# vibebuddy: managed, do not remove`, and uninstall does
`sed -i '' '/vibebuddy/d' <config>` (mirroring Vibe Island's approach). A future
`vibebuddy --install/--uninstall` helper will write/strip these automatically.

## Roadmap

- [x] Source routing + per-agent display (app understands all 8 sources)
- [ ] `--install/--uninstall` that detects installed CLIs and writes/strips
      marked hooks (Claude/Codex first, then the templates above)
- [ ] Per-CLI event-shape validation against the real tools
- [ ] Copilot observe-mode watcher
