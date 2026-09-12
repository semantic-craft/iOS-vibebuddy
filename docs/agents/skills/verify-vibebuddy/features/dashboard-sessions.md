# Dashboard sessions

The Mac Dashboard, menu-bar feed, and iPhone task list show every known Session in exactly one of the three states: `needsResponse`, `working`, or `done`, with project, model, and current activity when the hub has it.

## Sub-features

- `dash-working` shows a session that received `UserPromptSubmit` as `working`.
- `dash-done` shows a session that received `Stop` as `done`.
- `dash-need-permission` shows a Notification whose message contains `permission` as `needsResponse` + `waitKind=permission`.
- `dash-need-question` shows any other wait Notification as `needsResponse` + `waitKind=question`.
- `dash-empty` shows no sessions on a freshly launched isolated daemon.

## How to get to it (user POV)

- On Mac: click the menu-bar cat, then **Dashboard** in the footer control row (or the Open Dashboard hotkey).
- On Mac: stay in the menu panel and read the activity feed (Needs response pinned above the rest).
- On iPhone: after pairing, open the dashboard list (title is the Mac name).
- A coding-agent hook POST to the hub is what actually creates the rows the user sees.

## Driving it with control-vibebuddy

Preconditions:

- Isolated `vibebuddyd` is healthy (`control-vibebuddy doctor`).
- No leftover sessions named `vb-verify-work`, `vb-verify-done`, `vb-verify-ask`, `vb-verify-q`.
- You are not looking at the installed app on :9876.

- **Empty board.** Read the snapshot before seeding. Run `control-vibebuddy snapshot --pretty`. `sessions` is `[]`.
- **Working.** Start a turn. Run `control-vibebuddy hook --agent claude --json '{"hook_event_name":"SessionStart","session_id":"vb-verify-work","cwd":"/tmp/verify-gateway"}'` then `control-vibebuddy hook --agent claude --json '{"hook_event_name":"UserPromptSubmit","session_id":"vb-verify-work","cwd":"/tmp/verify-gateway"}'`. A second snapshot shows `id=vb-verify-work`, `status=working`, `project=verify-gateway`.
- **Done.** Finish another session. Run `control-vibebuddy hook --agent claude --json '{"hook_event_name":"SessionStart","session_id":"vb-verify-done","cwd":"/tmp/verify-docs"}'` then `control-vibebuddy hook --agent claude --json '{"hook_event_name":"Stop","session_id":"vb-verify-done","cwd":"/tmp/verify-docs","message":"Published the release notes."}'`. Snapshot shows `vb-verify-done` `status=done` and summary containing `Published the release notes.`
- **Needs permission.** Raise a wait whose message names permission. Run `control-vibebuddy hook --agent claude --json '{"hook_event_name":"Notification","session_id":"vb-verify-ask","cwd":"/tmp/verify-review","message":"needs your permission"}'`. Snapshot shows `status=needsResponse`, `waitKind=permission`, `project=verify-review`.
- **Needs question.** Raise a wait that is not a permission. Run `control-vibebuddy hook --agent claude --json '{"hook_event_name":"Notification","session_id":"vb-verify-q","cwd":"/tmp/verify-docs-review","message":"Which revision style should I use?"}'`. Snapshot shows `status=needsResponse`, `waitKind=question`.
- **Proof.** Run `control-vibebuddy evidence --label dashboard-sessions`. `snapshot.json` contains all four ids with the statuses above. On a Mac with a simulator pointed at this isolated port, a screenshot of the iPhone dashboard also shows `verify-review` / `verify-gateway` (optional; HTTP snapshot is the hub proof).

## Gotchas

- `project` is the last path component of `cwd`. Assert `verify-gateway`, not the full path.
- A Notification with Claude `notification_type` that is not a wait (for example `auth_success`) is dropped and creates no row.
- `quota_auto_resume*` Notifications become metadata, not `needsResponse`.
- This recipe seeds the hub. It does not prove a real Claude Code / Codex process, Glance pixels, or Watch complications.
- `UserPromptSubmit` without a later `Stop` stays `working`. Do not treat a later snapshot as `done` unless a stop (or equivalent) arrived.
