# ADR-0016: Cursor is observed through its hooks, its transcript and its own database — and answered through its hooks

- Status: accepted
- Date: 2026-09-12
- Supersedes / amends: nothing. Sits beside ADR-0009 (daemon security),
  ADR-0010 (always-allow), ADR-0011 (Codex through the app-server daemon).

## Context

Cursor was already a quota source (`CursorUsageProvider`). It was not a session
source: a Cursor chat never appeared in the three buckets, could not be approved
or answered from the phone, and could not be jumped to. Cursor is one of the four
first-class agents (vision Q5), and first class means the three states plus
remote approval (Q10).

Cursor 3.20 exposes four things worth reading, all verified on this Mac on
2026-09-12 against `cursor.com/docs/hooks`, `cursor.com/docs/cli/*`, the bundled
`~/.cursor/skills-cursor/create-hook` skill, and the files themselves:

1. **Lifecycle hooks** in one user-level `~/.cursor/hooks.json`, shared between
   the IDE's Agent panel and `cursor-agent`. Command hooks exchange JSON over
   stdin/stdout. Three of them can *decide*: `preToolUse`, `beforeShellExecution`
   and `beforeMCPExecution` answer `{"permission": "allow" | "deny" | "ask"}`.
   Two can *continue*: `stop` and `subagentStop` answer
   `{"followup_message": …}`, which Cursor submits as the next message.
2. **An agent transcript** per conversation, JSONL, with an explicit
   `turn_ended` line carrying `success` / `error` / `aborted`.
3. **Its own conversation index** in `globalStorage/state.vscdb`
   (`composerHeaders` + `composerData:<id>`), holding the chat's name, workspace,
   branch, model, context-token figures and Cursor's own `status`.
4. **A CLI** with `--resume <chatId>`, the only documented way to reopen a
   specific conversation.

What it does **not** expose: any way to interrupt a running turn, any deeplink
that opens a chat by id (`prompt`, `command` and `rule` are the only three), and
any contract for returning a tool *result* from a hook.

## Decision

**Observation is layered, and the layers have a fixed order of authority.**

- **Hooks** are the live source and the only one that can be answered. Sessions
  are keyed on `conversation_id` — the composer id — because that is also what
  names the transcript directory and the database row. One id, one session.
- **The agent transcript** is a *tail*, not an import: a transcript first seen at
  launch starts at end-of-file and replays nothing, so starting vibebuddy never
  rings a completion for yesterday's turns. While hooks are live for a
  conversation (fresh within two minutes) a transcript event may only
  corroborate — recorded as evidence, never moving the three states. Without
  hooks, or when the Cursor CLI does not send the event in question, the
  transcript is the live source.
- **The composer store** never moves the three states. It fills in what no hook
  carries (the chat's name, the tracked branch, the model, the real context
  window) and gives conversations with no live evidence a `historyOnly` row, the
  way imported Copilot sessions appear. It is read from a private read-only
  snapshot, so SQLite's own WAL bookkeeping can never write into Cursor's
  directory.

**The blocking gate is `preToolUse` alone.** It fires for every tool — shell
commands and MCP calls included — before Cursor's own permission check. Wiring
`beforeShellExecution` as well would raise two cards for one command, so it is
deliberately left unwired. The reply is Cursor's own flat `{"permission": …}`;
`ask` is never sent, because an empty body already means that and is what a
timeout answers with.

**A question is answered by denying it.** Cursor's `AskQuestion` arrives on the
same `preToolUse` gate. `updated_input` only rewrites a call, so there is no way
to hand an answer back as the tool's result. The documented path is taken
instead: the question is denied and the person's choice travels to the model in
`agent_message`, with `user_message` saying it came from vibebuddy. The model
reads the answer and carries on.

**A running turn is supplemented, never steered.** Text the phone sends for a
running Cursor turn is queued (one per conversation, replaced by a newer one,
expired after 30 minutes) and Cursor's own `stop` hook collects it as
`followup_message`. The composer says so before Send is tapped, because
"accepted" here means queued for the end of the turn, not injected into it. A
finished chat is continued the other way: `cursor-agent --resume <composer id>`
in a terminal. **Stop is refused**, not attempted — Cursor exposes no interrupt.

**The jump brings Cursor forward.** With no deeplink for a chat, a Cursor IDE
session's jump activates Cursor and, when the session records a project, opens
that folder so the right window is in front. A `cursor-agent` session started in
a terminal keeps the ordinary terminal jump.

## Alternatives rejected

- **Chrome DevTools Protocol + DOM polling** (what CursorRemote does): requires
  launching Cursor with `--remote-debugging-port`, depends on Cursor's DOM, and
  gives a local process full control of the editor. Rejected on all three counts.
- **Writing into Cursor's database or transcripts** to inject an answer.
  vibebuddy only ever reads Cursor's files, and only from private snapshots.
- **Headless `cursor-agent --print` for dispatch.** A headless run has nowhere to
  show its own prompts, and Cursor still raises them for anything a hook allows.
  A terminal window is watchable on the Mac and answerable from the phone.
- **The Cloud Agents API** (`POST /v0/agents/{id}/followup` and friends). It
  needs a `CURSOR_API_KEY` separate from both the app's and the CLI's
  credentials, so it is its own decision and its own ticket. Cloud agents are
  already *visible* — they carry `bc-`-prefixed ids and appear in the composer
  store like any other conversation.

## Consequences

- A Cursor conversation appears in the three buckets, with its name, branch,
  model and context usage; a command or MCP call can be approved or denied from
  the phone; a question can be answered from the phone; a supplement reaches a
  running turn at its next boundary; a finished chat can be continued; and the
  jump lands in Cursor.
- Nothing vibebuddy installs can block Cursor: no hook sets `failClosed`, and
  every failure path prints nothing, which Cursor reads as no opinion.
- Two sources describing one conversation is now a normal state, so the
  transcript's authority window (two minutes of hook silence) is a real tuning
  knob. Too long and a long single tool call loses transcript coverage; too short
  and a late-flushed line could revive a finished session.
- A Cursor release that renames `conversation_id`, moves the transcript, or
  changes the `composerHeaders` schema degrades one layer at a time rather than
  all three: the parser answers `.undecodable` (reported as an unknown version),
  the tailer finds no files, or the store reports `sourceUnreadable`.

## Amendment 1 (2026-09-13): a hosted CLI conversation is controlled over ACP

**Context.** The decision above says "Stop is refused — Cursor exposes no
interrupt". That is true of a chat in the IDE, whose only write path is its
hooks. It is not true of `cursor-agent acp`: the CLI runs as an Agent Client
Protocol server over stdio (cursor.com/docs/cli/acp) and offers
`session/prompt`, `session/cancel`, `session/request_permission`
(`allow-once` / `allow-always` / `reject-once`) and Cursor's own
`cursor/ask_question` (structured answers by option id), `cursor/create_plan`,
`cursor/update_todos` and `cursor/task`. The CLI and the IDE share one agent
runtime and one tool set, so the vocabulary and the question shapes are the
same on both.

**Decision.** A Cursor conversation vibebuddy starts itself is hosted by
`CursorACPMonitor`: one `agent acp` process per conversation, alive as long as
the daemon, observed through its `session/update` notifications
(`ObservationSource.acp`) and answered on the same pipe. For such a
conversation stop is `session/cancel` and the ending it produces is marked
`userStopped`; continue is the next `session/prompt`; a supplement for a
running turn is still queued (ACP has no mid-turn steer) and sent as the next
prompt the moment the current one returns — the same `CursorFollowupQueue` the
hooks drain, and the hook route steps aside for a hosted id so nothing is
delivered twice. Permission requests become cards through the same
`ApprovalRegistry` as the hooks; a deny rule or an exact always-allow answers
without one. Questions and plans are cards whose answers travel back in ACP's
own shapes; a typed answer Cursor's schema cannot carry travels as the reason
on a `skipped` outcome. While the host carries a conversation, Cursor's hooks
and transcript for the same id only corroborate.

Every session now carries a **control channel** (`ControlChannel`: `hook`,
`acp`, `appserver`, `cloud`, `none`), stamped by the daemon on each snapshot,
and `SessionActionSupport` decides availability and wording from it before the
agent kind. So an IDE chat (`hook`) still says "Stop this in Cursor on your
Mac", a hosted CLI conversation (`acp`) offers Stop on the phone and the Watch,
and a cloud agent (`cloud`, ADR-0017) cancels its run.

**Consequences.** A hosted turn ends when vibebuddy quits, and the phone is
told so at dispatch time. A request nobody answers blocks the turn, as the
protocol says; the card stays until answered or the turn is cancelled. Whether
`session/load` can take over a conversation the IDE created is still an open
probe (ticket cursor-integration/11); until it is answered, continuing a
finished IDE chat keeps going through `cursor-agent --resume` in a terminal.
