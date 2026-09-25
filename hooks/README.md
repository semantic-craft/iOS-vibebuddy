# Feeding agents into vibebuddy

Every wire-up is a fail-open POST to the local daemon — if no daemon is running it
fails instantly and never affects the agent.

## Installing (no Python)

This directory holds the **runtime** pieces only — shell scripts that need `sh`
and `curl`, and the OpenCode plugin. Installing them into each CLI's config is
done natively by `HookInstaller` (VibeBuddyMacCore), from the Mac app's Settings
(**Install / repair**, per-agent **Repair**, **Uninstall**) or headless:

```bash
cd VibeBuddyMac
swift run vibebuddyd hooks install                      # every detected CLI
swift run vibebuddyd hooks install --agent codex        # one CLI (repeatable / comma-separated)
swift run vibebuddyd hooks install --approval           # + the phone-approval gate where supported
swift run vibebuddyd hooks install --statusline         # Claude's status line only
swift run vibebuddyd hooks install --statusline --agent grok   # Grok's status line only
swift run vibebuddyd hooks status                       # per CLI, plus what Codex will run
swift run vibebuddyd hooks uninstall [--agent NAME]     # revert (remembered)
```

Detection is by config directory (no PATH scanning): **Claude, Codex, Grok,
Antigravity, OpenCode, Cursor**. Every install first copies these scripts to
`~/Library/Application Support/vibebuddy/bin/` and verifies them; configs name
only that path, so an app update or a moved checkout never changes a command
(`vibebuddyd` takes `--hooks-dir DIR` or `VIBEBUDDY_HOOKS_DIR`, then an app
bundle — its own, else `/Applications/VibeBuddyMacApp.app` — then this directory
found above its executable or the working directory, and prints which). Idempotent (a re-run changes nothing on
disk), reversible (removes exactly our entries — old bundle and checkout paths
included — and restores the status line), with a timestamped backup of every
changed config under `…/vibebuddy/backups/`. Codex uses its first-class
lifecycle hooks in `~/.codex/hooks.json`; `config.toml` and its `notify` command
are never written. `docs/multi-cli-hook-setup.md` § Installing lists the rules.

`--approval` installs the blocking phone-approval gate for the CLIs that have one
(Claude, the Codex CLI, Grok and Cursor); every other detected CLI gets a plain
install.

Claude hooks use the default decoder; Codex / Grok /
Antigravity are decoded per-source inside the daemon. (Note: Antigravity `agy`
1.0.5 *loads* its hooks but does not yet *execute* them — an agy-side bug; the
wiring is ready for when an agy update fixes it.)

## Claude Code and Claude Desktop

```bash
vibebuddyd hooks install --agent claude      # back up + install (hooks + status line)
vibebuddyd hooks uninstall --agent claude    # revert
```
Installs the high-signal lifecycle set the installed Claude Code knows (the
installer reads `claude --version` and gates newer events, since Claude skips a
settings file naming an event it does not know) into `~/.claude/settings.json`:
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
Existing hook groups are retained. It also appends the terminal-capture hook
(`capture-terminal.sh`, see below) as its own group on `SessionStart` and
`UserPromptSubmit`, so Codex sessions get a jump-to-terminal ref.

Status delivery is installed as `async: true`, which Codex runs in the
background without waiting for it. The one exception it enforces itself is
`SessionEnd`, forced back to synchronous with a warning, so that one is
installed synchronous. Handlers keep a three-second hook limit and the
forwarder uses a one-second local HTTP cap, so a missing daemon cannot delay
the agent either way. The blocking approval gate stays synchronous: Codex
applies a hook's decision only when it waited for it.

```bash
vibebuddyd hooks install --agent codex
```

### Trust: installing a hook is not the same as running it

Codex runs a hook only while its recorded trust still covers the hook's current
definition — event, matcher, command, timeout and `async`. Writing `hooks.json`
leaves every changed entry `modified` (or a new one `untrusted`), and Codex then
**skips it in silence**: no error, no warning, nothing in the logs. Start a
fresh Codex session, run `/hooks`, review the VibeBuddy entries, and trust them.

Install and `status` end by asking the running app-server daemon what it will
actually run, so a half-trusted installation is visible instead of mysterious:

```bash
vibebuddyd hooks status
```

The check is read-only: it never writes a `trusted_hash`, because trusting a
hook is the user's security decision. The Mac app makes the same call over its
existing daemon connection and shows the verdict in Settings. Because configs
name the stable `bin/` path, the command — and so the trust — survives app
updates; moving an older install (bundle or checkout path) to it needs one
re-trust.

### Remote approval (`--approval`, Codex CLI only)

```bash
vibebuddyd hooks install --agent codex --approval
```

Codex fires `PermissionRequest` only when it would prompt you — a shell
escalation, a patch outside the sandbox, managed network access — and it honours
a hook's `decision.behavior` there (`PreToolUse` accepts only `deny`). So
`--approval` replaces the fire-and-forget `PermissionRequest` group with a
blocking `hooks/approval-hook.sh codex` (`timeout: 30`) that posts to
`/approval?agent=codex`, and leaves the `PreToolUse` status forwarder in place.
The daemon answers in Codex's own contract:

```json
{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}
```

A phone `allow` is final; a `deny` carries a message the model sees. No decision
within 25s prints nothing and Codex shows its own prompt as usual. `Bash` and
`mcp__…` names are already the canonical vocabulary; `apply_patch` is decided as
`Edit`, with a `file_path` derived from the patch when it touches exactly one file
(so `Edit(<path>)` rules and "Always allow" apply) and path-less otherwise (always
asks, persists no rule). A plain install afterwards keeps the gate. Re-trust
via `/hooks` after installing, as after any `hooks.json` change.

**Codex Desktop is not covered**: it never runs `hooks.json`, and its approval
prompts are not written to the rollout, so a Desktop wait stays invisible to the
phone (see below).

### Codex Desktop

Codex Desktop (the Codex GUI inside ChatGPT.app, running `codex app-server`
over stdio) does not execute the user's CLI `hooks.json`, and its app-server
exposes no socket another process could attach to. VibeBuddy therefore tails the
local `~/.codex/sessions/**/rollout-*.jsonl` stream in addition to the CLI hooks.
`task_started`, tool records, `task_complete`, and `turn_aborted` feed the same
reducer, so desktop work appears without `/hooks` trust. On startup only
currently active desktop turns are restored; old completed rollouts are not
replayed into the dashboard.

What the rollout does and does not tell us:

- A Desktop thread is recognised by `session_meta.originator == "Codex Desktop"`
  **or** string `source == "vscode"`. Desktop stamps `originator` and uses
  `vscode` as the `source` enum default; the `source` fallback is kept so
  Desktop-family threads that stamp a different originator still surface.
  Observed locally (read-only, 2026-09-04 19:00, no writes to `~/.codex`):
  2231 rollouts under `~/.codex/sessions` + `archived_sessions` were either
  `Codex Desktop` (2203) or `codex_work_desktop` (28). String `source=vscode`
  occurred 828 times and sat only on those two originators (802 + 26); the
  other 1403 records used object `source.subagent`. The 26 parent
  `codex_work_desktop` threads (plus 2 subagent children) would be missed by
  an originator-only check. Fixtures treat CLI as `originator: "Codex CLI"`
  + `source: "cli"` and ignore it. This machine has no CLI or VS Code/Cursor
  IDE rollouts, so whether those hosts ever stamp string `source=vscode` is
  unverified. PR #8 kept the `source == "vscode"` fallback when it added the
  subagent skip — compatibility, not a doc reversal. A spawned subagent thread carries the same originator and is
  skipped by `thread_source == "subagent"` / `source.subagent`; the parent's
  collaboration records own it.
- Rollouts sit under their *start* date and a resumed thread keeps appending to
  that old file, so discovery walks every date directory and keeps files written
  within the last 30 minutes.
- `turn_context.model` / `thread_settings_applied` fill the model column;
  `token_count` fills context usage (`last_token_usage` minus reasoning tokens
  over `model_context_window`) and spend. Both are metadata only and never
  surface an idle thread.
- Archiving a thread moves its rollout to `~/.codex/archived_sessions/`; the
  vanished file ends the session.
- Codex does **not** persist approval or `request_user_input` prompts in the
  rollout, so a Desktop approval wait is invisible and cannot be answered from
  the phone. Only the `request_user_input` tool call itself is visible.


## Grok Build

```bash
vibebuddyd hooks install --agent grok              # ~/.grok/hooks/vibebuddy.json + status line
vibebuddyd hooks install --agent grok --approval   # + the blocking approval gate
vibebuddyd hooks uninstall --agent grok            # revert
```

Grok loads every `~/.grok/hooks/*.json`, so vibebuddy writes its own file and never
touches yours. Reload in the TUI with `/hooks` → `r`. Installed events:
`SessionStart`, `UserPromptSubmit`, `PreToolUse`, `PostToolUse`,
`PostToolUseFailure`, `Stop`, `StopFailure`, `StopCancelled`, `Notification`,
`SubagentStart`, `SubagentStop`, `SessionEnd` — one forwarder handler each
(`timeout: 5`), plus `capture-terminal.sh` on `SessionStart`/`UserPromptSubmit`.
`Stop` and `SubagentStop` are stop *gates*, so their handler exits 0 immediately;
a timeout or crash fails open and grok stops anyway.

Grok's own `Notification` event is the attention signal: `permission_prompt` shows
the session as waiting on you, and `idle_prompt` (about a minute after any turn
end) is the idle backstop for the turns that report no stop at all.
`task_complete` reports a *background* task and is ignored — it can fire mid-turn.

Grok also imports `~/.claude/settings.json` hooks through `[compat.claude]`. Those
copies arrive in the Claude shape without `?agent=grok`, so nothing depends on
them — but grok resolves an argument-less quoted `command` as a literal path
(`~/.claude/"/…/capture-terminal.sh"`, command not found), which is why the
Claude capture hook is installed as `"…/capture-terminal.sh" claude`: with an
argument both CLIs shell-parse it, and the script ignores `$1`. The Claude
approval gate has arguments too since WR-11 (`claude 60`), so Grok runs it as
well; `approval-hook.sh` exits at once when `GROK_HOOK_EVENT` is set and its
source is not `grok`, leaving Grok's own gate the only one that asks.

### Grok status line

Install also wraps `[ui.status_line]` in `~/.grok/config.toml` (Grok reads it
at startup, so new sessions pick it up): `type = "command"` naming
`vibebuddy-statusline.sh grok <key>`, which forwards Grok's status JSON to
`/statusline?agent=grok` and then runs the command you had configured, so the
row looks the same (no row when you had none). It fills the session's context
(`context_window.context_tokens` / `context_window_size`), cost, model, effort,
session name, branch and worktree; an absent cost stays unknown. Grok kills
whatever a status line run leaves behind, so for Grok the wrapper waits for its
1-second-bounded forward before exiting. Only a `[ui.status_line]` table is
edited, as text; everything else in the file keeps its bytes. A `builtin` row,
an inline `status_line = {…}`, dotted keys, a multi-line value or CRLF line
endings are left alone with a note (`--statusline` then exits non-zero).
Uninstall puts the table back exactly as it was (or removes the one vibebuddy
added). As with Claude, the wrapper always exits 0: a user row that prints
nothing and fails no longer shows Grok's `[status line: exit N]`, and a wrapper
whose `bin/` copy was deleted without an uninstall shows `exit 127` in every
new session.

Grok's session registry, `~/.grok/active_sessions.json` (`[cli]
session_registry`, on by default), is the liveness backstop: a session the
daemon saw listed whose `grok` process has exited (a clean exit drops the entry,
a killed terminal leaves a dead pid) ends at the next sweep (≤ 60 s) as if its
`SessionEnd` had arrived. An entry that vanishes while its process still runs
is left to the hooks. While a Grok leader answers in the Grok home
(`leader*.sock`), nothing is retired: a leader keeps a session running after
its terminal closes, and fires no `SessionEnd`.

### Grok remote approval

`--approval` swaps the fire-and-forget `PreToolUse` group for the blocking
`approval-hook.sh grok` (`timeout: 30`, every tool). A later plain install
(including the Mac app's Repair button) keeps the gate; only uninstall
removes it. **The phone's answer is
authoritative only when grok runs with `[ui] permission_mode = "always-approve"` in
`~/.grok/config.toml`.** In grok's `default` mode a hook `allow` only means "not
blocked": grok still raises its own TUI prompt afterwards and no external client can
answer it, so vibebuddy can surface the wait and deny, but not approve on your behalf.

## Daemon

The hooks target `http://127.0.0.1:9876/hook` (override with `VIBEBUDDY_PORT`).
Run the menu-bar app (`swift run VibeBuddyMenuBar`) or `vibebuddyd` so something
is listening.

## Remote approval (opt-in)

```bash
vibebuddyd hooks install --agent claude --approval   # the blocking gate on PermissionRequest
vibebuddyd hooks uninstall --agent claude            # removes it too
vibebuddyd hooks install --agent codex --approval    # Codex CLI: same gate, same event
```
Both gates sit on `PermissionRequest`, which fires only when the agent would stop
and ask — for Claude that is a permission prompt in default mode, or an uncertain
classifier in auto mode; tool calls the agent runs on its own never reach the
phone. The gate is a synchronous `hooks/approval-hook.sh` (`timeout: 30`) that
posts to `/approval`; the daemon first tries your `permissions.allow` / `deny`
rules and vibebuddy's own always-allow store, and only otherwise shows the card.
It answers `{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":
{"behavior":"allow"|"deny"}}}`; a phone decision is final, and no decision within
25s prints nothing, so the agent falls back to its own prompt. `bypassPermissions`
still fires the event but ignores the answer.

An older install put Claude's gate on `PreToolUse` — every tool call, held for
the phone. A plain install and `--approval` both migrate such a gate to
`PermissionRequest`; the daemon still answers a `PreToolUse` payload in that
event's `permissionDecision` contract (Grok's gate lives there by necessity).

Because a `PreToolUse` gate fires for every call, the daemon answers the ones
nobody needs to decide itself, so they never reach the phone or raise a Mac
banner: every call from a `bypassPermissions` session; read-only tools (Read,
Glob, Grep, LS, WebFetch, WebSearch, ToolSearch, TodoWrite, NotebookRead,
AskUserQuestion) in any mode; and the edit tools (Edit, Write, MultiEdit,
NotebookEdit) in `acceptEdits`. MCP tools are never treated as read-only, and a
native `permissions.deny` rule still wins. A `PermissionRequest` is never
short-circuited: by definition the agent would have asked.

## Terminal capture (jump-back)

`capture-terminal.sh` is installed automatically as a second hook group on
`SessionStart` and `UserPromptSubmit` by the Claude, Codex, and Grok installers'
install (and removed by uninstall). SessionStart catches new
sessions; UserPromptSubmit re-captures so a session that missed SessionStart
self-heals on its next prompt. The re-capture reports less than the first one —
it skips the Ghostty AppleScript probe, which is only valid while the surface is
focused — so the Mac *merges* each ref into the stored one field by field: a
later capture updates what it saw and never erases what it didn't. On each
event it POSTs the session's `session_id` (or Grok's camelCase `sessionId`;
`$GROK_HOOK_EVENT` is the last resort only, since grok exports it to every
process it spawns) plus
everything it can learn about where the session lives, to
`http://127.0.0.1:${VIBEBUDDY_PORT:-9876}/terminal`:

| level | fields | what it buys |
| --- | --- | --- |
| pane | `tmux`, `tmux_pane` | selects the pane, unzooming the window if it was zoomed |
| surface | `tty`, `iterm_session_id`, `wezterm_pane`, `kitty_window_id`, `kitty_listen_on`, `ghostty_terminal_id` | raises the session's own window/tab/split |
| app | `term_program`, `host_bundle_id`, `host_pid`, `cwd` | brings the host application forward |

Hooks run with a stripped environment and no controlling tty, so all of it comes
from one `ps` snapshot walked up the process tree (~100 ms). `host_bundle_id` is
the bundle identifier of the nearest GUI ancestor, which is the only handle an
embedded terminal (the Claude desktop app, Cursor, Zed, a JetBrains IDE) ever
gives us — and the only way to tell Cursor from VS Code, since both report
`TERM_PROGRAM=vscode`. Ancestors whose bundle is background-only
(`LSBackgroundOnly` or `LSUIElement`) are skipped and the walk keeps climbing:
the Claude Code CLI itself ships as such a wrapper `.app`, and its bundle id
never appears in `NSRunningApplication`, so recording it would make every jump a
no-op instead of raising the Claude desktop app that hosts it.

Ghostty exports no identifier for its surface, so it is asked for one over
AppleScript, at `SessionStart` only and capped at 2 s. The first such call raises
the system's Automation consent dialog; decline it, or set
`VIBEBUDDY_GHOSTTY_PROBE=0`, and Ghostty jumps fall back to matching on `cwd`.

The Mac app stores all of this as `AgentSession.terminalRef` and uses it to focus
the right terminal window when you press **Jump to terminal** in the Dashboard.
`bash capture-terminal.sh --print` (or `VIBEBUDDY_CAPTURE_DRY_RUN=1`) prints the
JSON instead of POSTing it — the quickest way to see what your terminal reveals.

The script's parsers are unit-tested against fixed strings (no process table, no
network, no AppleScript):

```
bash hooks/tests/capture-terminal-parsing.sh
```

Because the capture hook rides inside each CLI's own hook config, it needs the
same reload/trust step as any other change there: Codex requires re-running
`/hooks` in a fresh session to trust the new group; Grok requires reloading hooks
(`/hooks` → `r`, or a new session).

Grok resolves a quoted, argument-less `command` as a literal *path* (verified on
1.0.13): `"…/capture-terminal.sh"` becomes `<grok home>/hooks/"…"` and fails with
`command not found`. A command with an argument is shell-parsed instead, so both
the Grok installer and the Claude one (whose hooks Grok imports through
`[compat.claude]`) install the capture hook with an inert agent name argument —
`"…/capture-terminal.sh" grok` / `… claude`. The script reads stdin and the
environment, never `$1`.
