# "Always allow" persists in a vibebuddy-owned store, not in `~/.claude/settings.json`

**Status:** Accepted (2026-06-06) — decides `.scratch/mac-power-features/issues/03`.

## Context

The approval card offers approve / deny. Issue 03 adds **"Always allow"** and
**"Allow all for this session"**, so a persisted rule auto-resolves future matching
approvals. The issue flagged a conflict on *where* the rule is written:
roadmap-checklist-2026-06-05 §4 line 83 said the daemon's own `PermissionRules`;
a session handoff said `~/.claude/settings.json`.

Two facts decide it:

1. **vibebuddy already owns a blocking approval path.** The PreToolUse
   `approval-hook.sh` → daemon `/approval` → `ApprovalRegistry` flow returns the
   permission decision the CLI obeys. The daemon already runs `PermissionMatcher`
   against the **native** Claude allow/deny it reads from `settings.json`
   (`PermissionRules.load`). So the daemon can auto-resolve `.allow` from *any*
   rule source it consults — it does not need the rule to live in the CLI's config.

2. **open-vibe-island has no model to borrow here.** OVI answers prompts by
   *keystroke injection* (`KeystrokeInjector`); its `AgentIntentStore` records only
   hook-install intent, not permission allow-rules. It never persists an
   "always allow" rule. (It is GPL-3.0 anyway — study only, no code reuse.) The
   only real precedent is Claude Code's *native* `permissions.allow`, which
   vibebuddy already reads.

Writing to `~/.claude/settings.json` would: mutate the user's global Claude config
(consequential, needs a managed marker to stay reversible), only work for Claude
Code (not codex/qwen/… routed through the same approval hook), and be partly
redundant since the daemon already evaluates `settings.json` allow rules before a
prompt ever reaches vibebuddy.

## Decision

Persist always-allow rules in a **vibebuddy-owned store**, evaluated by the daemon's
`/approval` path — **do not write to `~/.claude/settings.json`.**

- A `VibeBuddyAllowStore` JSON file at
  `~/Library/Application Support/vibebuddy/permission-allow.json` holds vibebuddy's
  own allow patterns (same `Tool(arg)` grammar `PermissionMatcher` already speaks).
  It is plainly vibebuddy-managed and reversible (delete the file, or clear it from
  the UI).
- `/approval` decides against the **union** of native (`settings.json`) allow and the
  vibebuddy store; the deny list still wins over both.
- **"Always allow"** (`/decision` `decision:"alwaysAllow"`) resolves the current
  approval `.allow` *and* appends a conservative rule derived from the pending tool —
  for Bash the **exact** command (`Bash(<cmd>)`, never a `:*` prefix), for
  Read/Write/Edit/MultiEdit the target path, else the bare tool.
- **"Allow all for this session"** (`decision:"allowSession"`) resolves `.allow` and
  marks the session id; further approvals for that session auto-resolve until it ends
  (in-memory, not persisted).

Granularity: per exact command / per file path (conservative — over-asking is safe).
Both Mac and iOS send the same `/decision` values, so both benefit.

## Consequences

- No mutation of the user's global Claude config; rules are cross-CLI (anything
  routed through the approval hook) and trivially reversible.
- A persisted rule only auto-resolves while the daemon is up and the approval hook
  fires; daemon down → hook fails open → the CLI prompts in-terminal as normal. Safe.
- The store is consulted on every `/approval`; it is small and read cheaply. Covered
  by `VibeBuddyAllowStore` + `ApprovalRoutesTests` (always-allow persists and the next
  matching call auto-allows; session-allow resolves siblings).
- Does **not** retro-suppress Claude's *native* prompts for the same command (those
  never reach vibebuddy); that would require writing `settings.json`, explicitly out
  of scope here.
