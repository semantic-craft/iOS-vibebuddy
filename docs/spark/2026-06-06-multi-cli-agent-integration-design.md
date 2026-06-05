# Multi-CLI agent integration — design spec

**Status:** Spec (2026-06-06) · PRD: `.scratch/multi-cli-hooks/PRD.md`

How VibeBuddy ingests lifecycle events from many coding CLIs, adopting the
architecture proven by open-vibe-island (one forwarder + central normalization +
hygienic installer) instead of N per-CLI translator scripts.

## Architecture overview

```
CLI lifecycle event
   │  (each CLI's own hook/plugin mechanism)
   ▼
┌─────────────────────────────────────────────────────────────┐
│ EDGE                                                          │
│  • Claude-format CLIs (claude, qwen, kimi, qoder, factory,    │
│    codebuddy, droid): native hooks → forwarder, NO translate  │
│  • Grok / Antigravity: native command hook → forwarder        │
│  • OpenCode: JS plugin (normalizes at edge, has its own runtime)│
└─────────────────────────────────────────────────────────────┘
   │  POST /hook?agent=<source>   (one forwarder; stdin JSON passthrough)
   ▼
┌─────────────────────────────────────────────────────────────┐
│ DAEMON  (VibeBuddyServer / HookParser — central)             │
│  source-aware decoding:                                       │
│   - claude-shape  → existing HookParser                       │
│   - grok          → camelCase envelope decoder                │
│   - gemini/antigravity → Gemini event-name decoder            │
│  → normalized HookEvent → SessionReducer → snapshot           │
└─────────────────────────────────────────────────────────────┘
```

Principle (from open-vibe-island): **normalize centrally whenever the CLI hands
you raw JSON; only normalize at the edge when the edge is a real plugin runtime**
(OpenCode).

## Components

### 1. The forwarder (one, not N)

A single fail-open entry that reads the CLI's event JSON on stdin and POSTs it to
`http://127.0.0.1:<port>/hook?agent=<source>` (+ a `/terminal` capture on session
start). Replaces the per-CLI curl scripts. Two acceptable forms:

- **Script** (`hooks/vibebuddy-forward.sh <source>`): `curl … --data-binary @-
  "…/hook?agent=$1"`, plus the existing `capture-terminal.sh` logic for `/terminal`.
- **Small binary** (future): like open-vibe-island's `OpenIslandHooks --source`,
  if/when we move to a UDS or need richer behavior.

Claude-format CLIs need nothing more than pointing their native hook command at the
forwarder with the right `<source>`.

### 2. Central normalization (daemon)

`HookParser` becomes source-aware (the `?agent=` value selects a decoder), each
returning the existing internal `HookEvent`:

- **claude-shape** (claude + all forks incl. **qwen**, kimi): current parser. No
  change — they already emit `{hook_event_name, session_id, cwd, tool_name,
  tool_response.is_error}`.
- **grok**: envelope is **camelCase with snake_case values** (`{"hookEventName":
  "pre_tool_use", "sessionId", "cwd"/"workspaceRoot", "toolName", "toolResult"}`).
  Decoder maps `hookEventName` snake values → PascalCase kinds; `toolResult.isError`
  → `is_error`. (Grok also exposes `GROK_HOOK_EVENT/GROK_SESSION_ID/
  GROK_WORKSPACE_ROOT` env, usable if the forwarder prefers env over stdin.)
- **gemini / antigravity**: Gemini-CLI event names (`SessionStart`, `BeforeAgent`→
  UserPromptSubmit, `BeforeTool`→PreToolUse, `AfterTool`→PostToolUse, `AfterAgent`→
  Stop, `SessionEnd`). **Antigravity 2.0 may instead use `PreToolUse`/`PostToolUse`
  + a JSON-out `{"decision":"allow"}` contract** — the decoder must accept both
  spellings; the live `/hooks` TUI is the source of truth (verify on a real run).

Decoders are pure → **Swift unit tests per source** (a recorded sample envelope →
expected `HookEvent`), living beside `HookParserTests`.

### 3. OpenCode plugin (edge)

`~/.config/opencode/plugins/vibebuddy.js` (plural `plugins/` dir — confirmed by
OpenCode docs + binary + VibeIsland). Uses `@opencode-ai/plugin` Hooks: `event`
(`session.created`→SessionStart, `session.idle`→Stop, `session.deleted`→SessionEnd),
`chat.message`→UserPromptSubmit, `tool.execute.before`→PreToolUse,
`tool.execute.after`→PostToolUse (is_error best-effort — OpenCode's after-hook has
no error flag). Fail-open `fetch`, dependency-free, never throws. Terminal capture
via `process.env.TERM_PROGRAM` (reliable) + best-effort tty/tmux.

### 4. Universal installer

`hooks/install-agent-hooks.py` (or evolve `install-claude-hooks.py`). Per detected
CLI, a handler that knows its config dir + format. Shared hygiene (from
open-vibe-island):

- **manifest sidecar** per agent (e.g. `~/.qwen/vibebuddy-install.json`) recording
  the exact installed command + timestamp + any flag it toggled.
- **marker** for non-sidecar formats (TOML/`config.toml`): `# vibebuddy: managed`.
- **timestamped backup** before every mutating write.
- **sanitize-then-append** idempotency (strip prior managed entry by manifest/exact-
  command/legacy-name, then re-add); byte-compare to report "changed".
- **only undo what you enabled** (e.g. a CLI's hooks feature flag).
- `--install` / `--uninstall` / `--dry-run`; detect = read each CLI's config dir,
  not PATH-scan; never surprise-install.

Per-CLI handlers:

| CLI | writes | format notes |
|---|---|---|
| claude / qwen / kimi / qoder / factory / codebuddy | `~/.<cli>/settings.json` `hooks` | JSON map; point at forwarder `--source <cli>` |
| qwen (alt) | `~/.qwen/settings.json` | native `http` hook → `/hook?agent=qwen` (no forwarder needed) |
| codex | `~/.codex/hooks.json` + `config.toml` flag | version-dependent flag key; un-set only if we set it |
| grok | `~/.grok/hooks/vibebuddy.json` | command hooks → forwarder `--source grok` (http blocks loopback) |
| antigravity | `~/.gemini/antigravity-cli/settings.json` (or plugin dir) | command hooks; verify event names |
| opencode | copy `vibebuddy.js` → `~/.config/opencode/plugins/` + register in `config.json` | JS plugin |

### 5. Security (see `.scratch/daemon-security/issues/01`)

`/hook` + `/terminal` are currently unauthenticated on `0.0.0.0`. Decide before
broad install: (A) token (install-time secret in the forwarder command) + Origin/
Host checks; (B) split loopback-only listener; (C) UDS for the CLI path (open-vibe-
island's model). The forwarder + installer must carry whatever the decision needs
(e.g. write the token into each CLI's hook command).

## Data flow (example: Qwen)

```
qwen SessionStart → ~/.qwen/settings.json hook (native http) →
  POST /hook?agent=qwen  {hook_event_name:"SessionStart", session_id, cwd, …} →
  HookParser (claude-shape) → SessionReducer → snapshot → Mac + phone show a
  session tagged agent=qwen
```

## Edge cases

- **Claude-fork id collisions:** forks reuse the Claude shape; `?agent=` keeps them
  on separate AgentKinds. Verify session ids don't collide across CLIs (they're
  per-CLI UUIDs; the store keys by session_id — fine).
- **Grok auto-bridges `~/.claude/settings.json`** (`[compat.claude]`): our Claude
  hooks already fire under Grok but get dropped (wrong shape, no `?agent=grok`).
  Install a dedicated `~/.grok/hooks/vibebuddy.json` and don't rely on the bridge.
- **Antigravity event names** unknown until live-checked; decoder accepts both.
- **Fail-open everywhere:** a dead daemon must never stall a CLI (curl `--max-time`,
  `|| true`; plugin swallows errors).
- **terminalRef capture** for grok/antigravity is secondary; reuse `capture-terminal.sh`
  where the stdin carries `session_id` (Claude-shape); grok needs `GROK_SESSION_ID`.

## Testing

- **HookParser per-source decoders:** Swift unit tests (recorded envelope → HookEvent)
  for grok + gemini/antigravity, alongside existing `HookParserTests`.
- **Installer:** Python idempotency test (install twice → no dup; uninstall → clean;
  backup created) like the existing capture verifier.
- **Live smoke (HITL):** run each CLI, confirm a session appears tagged correctly +
  terminalRef; for Antigravity confirm event names via `/hooks` TUI first.

## Phasing

P1 Qwen + OpenCode (no daemon change) · P2 daemon normalization + Grok + Antigravity
· P3 universal installer · P4 security. (See PRD.)

## Open decisions

1. Forwarder = shell script vs small binary (binary needed only if we go UDS).
2. Security transport: token+origin (A) vs loopback split (B) vs UDS (C).
3. Antigravity event-name spelling (resolve via live `/hooks`).
4. Qwen: native `http` hook (zero forwarder) vs forwarder `command` (uniform with others).

## Out of scope (v1)

IDE-extension jump (.vsix), Copilot, SSH/remote agents, closed-app forwarding.
