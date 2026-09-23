# ADR-0023: The handoff stays Matt Pocock's handoff document; the Mac fills in its facts and starts the receiver from it

- Status: accepted as the design on 2026-09-14 (owner decisions: Mac first,
  fact collection on by default, follow the `handoff` skill's thinking
  throughout); implementation authorized the same day and delivered on
  `feat/handoff-continue` (tickets 01–05 in `.scratch/handoff-continue/`,
  acceptance in `acceptance/05/README.md`: a real Codex continued from the
  handoff path alone; pressing Start could not be exercised in the isolated
  instance, which has no launchers by design).
- Date: 2026-09-14
- Amends: ADR-0019 (the relay half). Its read-only contract for
  `vibebuddy-mcp`, its Session key / History reference / Handoff note terms
  and its "never fill `Source session` from the newest session" rule stand.
  Its sentence "no background-launch or dispatch mechanism is added for
  relay" is narrowed: relay still starts through the existing human entry
  point (the Mac's New task sheet and `POST /dispatch`, ADR-0009 routes), now
  prefilled from a handoff. ADR-0020 (the Mac is the progress desk) and
  ADR-0021/0022 (Recap, pending queue) stand.
- Source: `.scratch/handoff-continue/PRD.md`.

## Context

Cross-agent continuation is context transfer, never state transfer: Codex
cannot load a Claude transcript, and `claude --resume` only reopens the same
agent in the same terminal. What can travel is a document. The
[`handoff` skill](https://github.com/mattpocock/skills) by Matt Pocock
(read 2026-09-14: `skills/productivity/handoff/SKILL.md`,
`docs/productivity/handoff.md`, `skills/in-progress/claude-handoff/SKILL.md`)
defines that document and, more usefully, the discipline around it:

- A handoff is written **on purpose**, by the person typing `/handoff`
  (`disable-model-invocation: true`); the agent never fires it itself. It
  buys portability, not compression; it exists only when work travels: to
  another harness, another directory, a colleague, or a forked side task.
  For the ordinary end of a phase, `/compact` is the move.
- It carries the live thread and nothing already written down: goal, settled
  decisions, authorization, current work state, validation evidence,
  outstanding work, suggested skills. Specs, plans, ADRs, issues, commits and
  diffs appear as paths and URLs. Secrets are redacted. The argument ("what
  the next session is for") shapes what is kept.
- The receiver is **pointed at the file path**, never handed the summary
  inside a shell command (backticks and `$(...)` truncate silently).
- The fork case is the one people skip: the writer stays in its session and a
  second agent runs in parallel with a copy of the context.
- Its own documentation names the frictions: the temp directory loses or
  hides the file; the document records the what and not the why; and a
  belief the session never verified, written as a fact, becomes the
  receiver's false premise, because the receiver treats the document as a
  contract and does not re-check it. The in-progress `claude-handoff` shows
  the direction the author is taking: do not save the summary, seed a
  background agent with it (`claude --bg --name … "<summary>"`), Claude only,
  same directory.

ADR-0019 already adopted this document as vibebuddy's relay: the
`vibebuddy-handoff` skill wraps the original, moves the file from the temp
directory to `.scratch/<feature>/handoffs/`, and prepends four lines (`Source
session`, `Ticket`, `Branch`, `Worktree`). One real Claude Code → Codex relay
was accepted on 2026-09-13 (`.scratch/agent-mcp-cli/acceptance/12/`). Two of
Matt's frictions are therefore already handled (durable location, source
identity). Three remain, and they are exactly where vibebuddy holds facts no
skill can see:

- **Unverified claims.** The daemon records every session's tool calls in
  `tool-ledger.json` (`ToolLedger`, `ToolCallRecord`: command text capped at
  2000 characters and exit code, from Claude-shaped hooks and the Codex
  app-server; tool name only from Cursor ACP and the Codex rollout tailer),
  changed files and line counts, and each round's outcome in
  `lifecycle-journal.json`. `WorkspaceChangesReader` can probe a checkout's
  git state on demand. Nothing on `AgentSession` stores HEAD or dirty state.
- **Finding the file, and handing it over.** No code reads `.scratch` or
  handoff paths today; the Mac cannot show that a handoff exists, and
  starting the receiver is a manual paste. The Mac already has the entry
  point: `NewTaskSheet` → `DispatchRequest{agent, cwd, prompt, name, model?,
  mode?, worktree?}` → `POST /dispatch`, which starts Claude (`--bg`, the
  job's `state.json` gives the session id), Codex (app-server thread) and
  Cursor (ACP, optionally in a fresh worktree). `snapshot.dispatchAgents`
  says which can start now. Finished-session actions live in the row's
  context menu (`DashboardView.swift`) and the detail title bar
  (`SessionTitleBar` in `DashboardDetail.swift`).
- **Lineage.** Nothing records that session B continued session A.

## Decision

**1. The handoff document is the contract, unchanged.** Matt's sections, his
trigger conditions, his reference-by-path rule, his redaction rule, his
"point at the path" delivery, and his user-only invocation all stand.
vibebuddy adds no automatic handoff generation: a handoff is still written
when a person asks for one. What vibebuddy adds is facts under the document,
a place to see it, and a way to start the receiver from it.

**2. Handoff facts: collected by default, read on request, never written by
a model.** A new read-only tool `vibebuddy_handoff_facts` (CLI `facts`) in
`vibebuddy-mcp` takes a Session key and prints, as Markdown, the block the
handoff's header and its "Validation evidence" section need:

- the four header lines with `Source session` set to the key the writer
  supplied (the tool validates that the key exists; it never picks one),
  `Branch` and `Worktree` from a live git probe of the session's checkout
  (falling back to the session's own fields), and `Ticket` left for the
  writer, with the `.scratch/<effort>/` directories the session touched
  listed as candidates;
- a **Facts** section: agent, started / last activity, rounds ended
  (completed / failed / user-stopped) from the lifecycle journal; HEAD,
  branch, modified and untracked files from the git probe, stamped "as of
  <time>"; files edited and commands run with exit codes from the tool
  ledger (the last 20, newest last); and a **coverage line** naming which of
  these the session's observation path can report at all.

Collection is not new work and has no toggle: the ledgers this reads are the
ones the daemon keeps today, on by default, seven days. "Default on" means
the facts are there whenever someone writes a handoff, not that a handoff is
written for them. The tool reads files the app publishes atomically and
never opens the daemon; when the git probe cannot run it says so.

The `vibebuddy-handoff` skill calls `facts` first and pastes the block; the
writer's own sections stay the writer's. Validation evidence is the one place
the two meet: the facts say what ran and how it exited, the writer says what
that proves, and anything the facts do not show stays `[unverified]`. This is
Matt's "downgrade anything you only assumed", made checkable.

**3. Handoff records: the Mac knows which handoffs exist.** At snapshot
time the Mac scans `.scratch/*/handoffs/*.md` under the snapshot's
`recentDirectories` (directories a session already ran in; nothing else is
read), parses the four header lines of files that begin with `Source
session:`, and carries them as `snapshot.handoffs: [HandoffRecord]` (path,
source key, ticket, branch, worktree, written at, taken by). The file remains
the only truth; there is no registry to write, no retention to manage, and no
write tool in `vibebuddy-mcp`. A session row whose key is a record's source
shows a **Handoff ready** mark; a record with `Source session: unknown` is
listed under its directory, not under a session.

**4. Continue with…: the receiver starts from the document, on the Mac
first.** A finished session's context menu and its detail title bar gain
**Continue with…**, listing `dispatchAgents`. Choosing one opens the New task
sheet prefilled: the chosen agent; `cwd` = the session's checkout; the prompt
in Matt's delivery form, `Read <absolute handoff path>, then continue.`,
followed by `Continues: vibebuddy://session/<key>`. With no handoff record for
that session the prompt instead points the receiver at `vibebuddy-mcp facts`
and `vibebuddy-mcp show` for that key (`Continues: <key>`), which is ADR-0019's
reader flow. (Since 2026-09-23 there is no history index behind either; see
ADR-0019's amendment.) The person reviews and presses Start; nothing is sent without
that press, so the "human action through the existing entry point" sentence
of ADR-0019 holds. The writer's session is untouched: this is Matt's fork
case as much as his swap-harness case.

When the live snapshot shows another session working in that checkout, the
sheet says so and offers the directory picker (and, for Cursor, the existing
worktree toggle). It never switches directories on its own; live status is an
observation, not a lock (ADR-0019).

**5. Lineage comes from the dispatch, not from prompt parsing.** The Mac
started the receiver, so it knows the new session's id (Claude `state.json`,
Codex thread id, Cursor ACP) and which handoff it was started from. It
records `takenBy` on the handoff record's in-memory state and
`continuesSessionKey` on the new session for the life of that session; the
lifecycle journal's field policy (no prompts, no paths) is unchanged, so
lineage does not survive a daemon restart in the first version. The journal
never stores prompt text, and `Continues:` in a prompt is a convention for
the receiver, not something the daemon reads.

**6. The receiver's drift check.** `vibebuddy-history` gains one step: after
reading the handoff, run `facts` for its source key and compare HEAD, branch
and dirty files with what the handoff recorded. A moved HEAD or a changed
file list is reported to the user before work resumes. This is Matt's
"recheck drift-prone facts when continuing", with the facts supplied.

## Alternatives rejected

- **Generating a handoff automatically at every round end.** Contradicts the
  skill's premise that a handoff is a deliberate transit document, and would
  produce a model-written secondary source nobody asked for. Facts are
  collected by default; documents are not.
- **A `register` or `handoff write` command in `vibebuddy-mcp`.** ADR-0019's
  read-only contract. Discovery by scanning the handoff directories of known
  checkouts needs no write path.
- **Seeding the receiver with the summary text, as `claude-handoff` does.**
  Matt's own documentation warns that a summary interpolated into a shell
  command truncates silently; it also limits relay to Claude in the same
  directory. The path is what travels.
- **Detecting lineage from `Continues:` in the receiver's first prompt.** The
  daemon would have to read prompt text, which the journal policy forbids,
  and hook coverage of prompt text differs per agent. The Mac already knows
  what it started.
- **Storing HEAD and dirty state on `AgentSession` continuously.** A git
  probe per snapshot per session for a value only a handoff needs. On demand
  at `facts` time is enough, and it is honest about its timestamp.
- **Phone or Watch first.** The owner chose the Mac; the dispatch surface,
  the directory picker and the detail view are already there. The phone's
  Continue is the next step, not this one.

## Consequences

- `CONTEXT.md` gains **Handoff facts**, **Handoff record**, **Continue
  with**; the **Handoff note** entry gains the facts block.
- `vibebuddy-mcp` grows a seventh read-only tool; the CLI/MCP byte-identity
  test, the store-unchanged test and the schema-validated argument path
  cover it like the others.
- `docs/agents/skills/vibebuddy-handoff/SKILL.md` and
  `vibebuddy-history/SKILL.md` change; the original `handoff` skill is not
  modified.
- The Mac gains a row mark and one menu item; `NewTaskSheet` accepts a
  prefill; `/dispatch` responses already carry the new session id.
- Acceptance is a real Claude Code → Codex continuation on one Mac through
  Continue with…, plus the fork case (the writer still running afterwards),
  with the coverage line checked against a Cursor ACP session.
- Out of scope: iPhone and Watch Continue, cross-machine handoffs, LLM
  summaries of facts, lineage that survives a restart, any write path.

## Amended 2026-09-14: after the first acceptance

Source: `.scratch/handoff-continue-hardening/spec.md` (owner decisions A, B
and C on 2026-09-14). The first real Codex continuation
(`.scratch/handoff-continue/acceptance/05/`) showed three things the first
version got wrong; the decision changes accordingly.

- **§5 is replaced: lineage survives a restart.** `continuations.json` beside
  the other ledgers (owner-only, atomic, seven days from `recordedAt`) holds
  one record per Continue with… the Mac dispatched: `receiverKey`,
  `sourceKey`, `handoffPath?`, `recordedAt`. A session's
  `continuesSessionKey` and a handoff record's `takenBy` (now Session keys)
  are derived from it; `facts '<receiverKey>'` prints
  `- Continues: <sourceKey> (started by the Mac from …)` as soon as the
  record exists, before the receiver's first hook. Lineage is recorded where
  the task was started, by the Mac app's dispatch and by the daemon's
  `POST /dispatch` alike. The lifecycle journal's field policy is unchanged.
- **§3 and §4: the checkout is remembered, never guessed.**
  `recent-directories.json` (same protections) keeps the directories a task
  may start in and, per session, the checkout it was observed in. After a
  restart a journal-restored session gets its own checkout back;
  `recentDirectories` and `snapshot.handoffs` are immediately populated. A
  session whose checkout was never observed keeps none: a folder with the
  same name is not evidence. Continue with… therefore prefills the directory
  only from the session itself and otherwise leaves it empty for the person
  to choose; the earlier fallback to the newest directory is removed. The
  seven-day cutoff is also applied when paths are listed or authorized during
  a long-running process, without requiring a restart.
- **§4: Codex may write in the handoff's effort directory.** A
  `DispatchRequest` may carry `continuation {sourceKey, handoffPath?}`. Both
  dispatch entry points require a supplied handoff path to canonically match
  a currently scanned document naming that source session before invoking a
  launcher; an arbitrary path with the right directory shape is insufficient. For a
  Codex dispatch whose handoff resolves (symlinks followed) to a
  `.scratch/<feature>/` outside the checkout — an agent worktree's `.scratch`
  is a link into the main checkout — the Mac takes the sandbox policy
  `thread/start` reports for the new thread and, only when it is
  `workspaceWrite`, appends that one directory to `writableRoots` on
  `turn/start`. Network access, temp-directory rules, the existing roots and
  the approval policy are the thread's own; `readOnly`, `dangerFullAccess`
  and a daemon that reports no policy are left untouched. Per the app-server
  contract a policy passed to `turn/start` becomes that thread's default for
  later turns, so the grant lasts for the whole continued task and no longer.
  The prompt's extra line ("if your sandbox refuses to write there, report
  the text instead") remains a fallback, not the fix. It is recomputed from
  the final selected checkout when the directory changes and at dispatch,
  preserving the person's other prompt edits.
- Consequences: `CONTEXT.md` gains **Continuation record**; Handoff record,
  Continue with… and Recent directories are updated. `vibebuddy-mcp` reads
  two more files and still writes none. Acceptance for this amendment runs
  through the isolated daemon's `/dispatch` against a real Codex, with a
  restart in the middle (`.scratch/handoff-continue-hardening/acceptance/`).
