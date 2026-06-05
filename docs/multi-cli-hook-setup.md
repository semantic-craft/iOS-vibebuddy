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
| Codex | `codex` | `~/.codex/config.toml` | TOML `[hooks]` / notify | ✅ tested |
| OpenCode | `opencode` | `~/.config/opencode/` plugin | Claude-compatible hooks | ⚠️ template |
| Qwen Code | `qwen` | `~/.qwen/` | Claude-compatible hooks | ⚠️ template |
| Kimi | `kimi` | `~/.kimi/config.toml` | TOML hooks | ⚠️ template |
| Antigravity (Gemini) | `antigravity` | `~/.gemini/.../plugins/` | plugin | ⚠️ template |
| Grok | `grok` | per-CLI hooks | Claude-compatible hooks | ⚠️ template |
| GitHub Copilot | `copilot` | — | observe mode (no hooks) | ⚠️ partial |

✅ = wired and exercised. ⚠️ template = the source routing + display are done in
the app; the config snippet below needs validation against the installed CLI.

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

Other hook-compatible CLIs (OpenCode, Qwen, Grok) follow the same shape with
`agent=<their source>`. Kimi/Codex use their TOML hook tables; Antigravity uses
a Gemini plugin that shells out to the same curl. Copilot has no hook surface
yet — it appears once a future watcher observes it.

### Terminal capture (for jump-to-terminal)

Jump-to-terminal needs to know which terminal each session runs in. A second hook,
`hooks/capture-terminal.sh`, POSTs `{session_id, term_program, tty, tmux, tmux_pane}`
to `/terminal`. `install-claude-hooks.py` wires it to **both `SessionStart` and
`UserPromptSubmit`**: SessionStart catches new sessions, and UserPromptSubmit
re-captures so a session that missed SessionStart — e.g. the hook was added while
the session was already open — **self-heals on its next prompt** (writing the same
ref is idempotent). A session with no captured terminal can't be jumped to (the iOS
button hides; the Mac button disables; a phone jump reports "no terminal").

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
