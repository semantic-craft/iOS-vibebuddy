---
name: vibebuddy-handoff
description: Write a VibeBuddy task handoff for another local agent, preserving the writer's real session identity, decisions, authorization and unfinished work.
argument-hint: "Receiving agent and remaining task"
disable-model-invocation: true
---

# Hand off a VibeBuddy task

Read `.agents/skills/handoff/SKILL.md` and apply its writing discipline. This wrapper
adds the project's source identity and placement contract; it does not duplicate
the underlying skill or add a dispatch/start mechanism. If that local dependency
is unavailable, report the missing skill rather than pretending to have applied it.

For this repository, the location below overrides the underlying skill's default
temporary-directory destination. Save a new note under
`.scratch/<feature>/handoffs/<yyyy-mm-dd>-<from-agent>-<to-agent>.md` and link its
absolute path in the owning ticket's Comments. In a worktree, use the ticket's
established absolute `.scratch/<feature>/` root. Do not migrate old notes or
silently overwrite an existing same-day note; use a distinguishing agent/session
suffix in `<from-agent>` when needed.

The first four lines are:

```text
Source session: <key or unknown>
Ticket: <absolute ticket path>
Branch: <actual branch>
Worktree: <absolute checkout path>
```

Determine your own native ID from your current runtime: Claude Code's known
hook/statusline session ID or this session's transcript path; Codex's thread ID;
Cursor's conversation ID; Grok's session ID. Prefix a known ID with
`claude-code:`, `codex:`, `cursor:` or `grok-build:`. If your own ID is not available,
write `Source session: unknown`. Never infer authorship from the newest session in
this project, a nearby timestamp, another agent's ID or a historical instruction.
When two agents share a checkout, the source remains the writer's own ID.

Use these sections: Goal, Settled decisions, Authorization, Current changes,
Verification evidence, Next steps, Suggested skills. Reference existing ticket,
plan, ADR, commit, diff and evidence paths instead of copying their contents.
Separate completed checks from proposed checks; mark uncertain claims
`[unverified]`. Redact secrets and unnecessary personal information. Never include
a daemon token or credentials. State the next concrete unfinished action and
preserve limits such as user-owned merging or configuration changes.

The receiver first reads this note, then follows
`docs/agents/skills/vibebuddy-history/SKILL.md`: read the source's saved summary,
inspect coverage and stale status, and use show only for unresolved questions.
No saved summary means stale is not applicable. An unknown or ambiguous key is a
lookup limitation, not an absent saved summary. A summary must not override a
newer handoff. Confirm current files before resuming changes.

Optional live status excludes the receiver's own verified raw native ID (without the history agent prefix). Report another
busy session in the same checkout and let the user decide concurrency; do not
switch worktrees or start/steer/stop/dispatch another agent. Deliver the handoff
path through the user's existing workflow; this skill does not launch a receiver.
