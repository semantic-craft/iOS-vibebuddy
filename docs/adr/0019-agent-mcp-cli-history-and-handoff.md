# ADR-0019: Agents read local session history and live status through one read-only `vibebuddy-mcp` binary; relay between agents is a handoff note that names its source session

- Status: accepted in direction, first version scoped by the owner on 2026-09-13; implementation authorized by the owner on 2026-09-13 (tickets in `.scratch/agent-mcp-cli/`)
- Date: 2026-09-13
- Supersedes / amends: nothing. Sits beside ADR-0009 (daemon routes need the
  bearer token), ADR-0011 (Codex through the app-server daemon), ADR-0016 and
  ADR-0018 (Cursor sources). Turns the "MCP/CLI access" line in
  `docs/session-history.md` from future work into a decision.

## Context

vibebuddy already owns the data this decision exposes. `SessionHistoryRepository`
indexes Claude Code and Codex conversations under
`~/Library/Application Support/VibeBuddy/SessionHistory`; `SessionHistorySearchIndex`
is an FTS5 trigram index over readable message text; the Mac dashboard's History
scope reads, searches, exports and summarises those conversations. Only the Mac
app loads the repository, and nothing outside the app can ask it anything.

**What that data layer is not:** a service another process can safely open.
Three facts, checked against the source on 2026-09-13, bound the work:

- Full-text reading does not parse the agent's file. `session(id:)` decodes the
  per-source cache `SessionHistory/<sha256 of path>.json` that the last refresh
  wrote, so a reader that never refreshes reads whatever the app last cached.
- `SessionHistorySearchIndex` opens `search.sqlite` with
  `SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE` and lazily builds message rows on
  the first query. There is no read-only path.
- Consistency is a Swift actor, which holds inside one process only. `index.json`,
  the content caches and `search.sqlite` are written without any cross-process
  lock, so a second writer (or a reader during a write) is undefined behaviour
  today.

So this is not "one more exit layer over an existing index". The reading and
index code has to be made safe for a second process before any tool is worth
exposing, and the tickets are ordered that way.

Agents cannot see any of this history. A Codex session that picks up a task
Claude Code left has no way to find that conversation. The practice today is a
hand-written handoff file inside a ticket
(`.scratch/watch-complication/issues/01-handoff.md` and siblings). Those files
carry the outgoing agent's intent, which is exactly what a summary written
later by another model cannot recover, but they never name the conversation
they came from.

[Wake](https://github.com/iAmCorey/Wake) (read 2026-09-13: `docs/mcp.md`,
`docs/cli.md`, `crates/wake-core/src/mcp/tools.rs`, `cli.rs`,
`skills/wake/SKILL.md`) is the interface to copy: four read-only tools
(`search`, `list_sessions`, `get_session`, `list_projects`) that answer in
Markdown; every hit carries a `wake://session/<key>#<seq>` reference and
`get_session` pages by `from_seq`; `project` takes the agent's working
directory; the CLI is argv-to-JSON over the same tool layer and a test asserts
the two surfaces print identical bytes; exit `0` includes "no matches" and `2`
means no usable index; every listing ends with an index-freshness line; the
server never scans; `setup` prints per-client config; a bundled skill makes
agents reach for it unprompted. Its code is Rust and is not reused.

The `handoff` skill in [mattpocock/skills](https://github.com/mattpocock/skills)
(already linked at `.agents/skills/handoff`) supplies the writing discipline for
the relay half: reference specs, tickets, ADRs and diffs by path instead of
copying them; redact secrets; name the suggested skills; write for the stated
next task; downgrade anything the session assumed but never verified. Its
storage choice (the OS temp directory) is the part its own documentation lists
as the most reported friction, and it is not adopted.

Grok Build has, since this Mac's `grok 1.0.30`, an official way to enumerate and
export sessions: `grok sessions list` / `grok sessions search <query>` (search
covers summaries and first prompts only) and `grok export <session-id> [OUTPUT]`
(Markdown, stdout by default). Those are the documented interface; the
`~/.grok/sessions/**/updates.jsonl` layout that live observation reads
(`GrokSessionReader`) is not. Ticket 07 verified official list and three local
exports without a leader while denying file writes and child-process creation.
That proves command availability under those protections, not transcript fidelity.

## Decision

**One binary, `vibebuddy-mcp`.** A new executable target in
`VibeBuddyMac/Package.swift` on `VibeBuddyMacCore`, shipped inside the Mac app
bundle at `Contents/MacOS/vibebuddy-mcp`. With no arguments it serves MCP over
stdio; with a subcommand it is the CLI over the same tool layer, so the two
surfaces cannot drift. No alias or symlink in the first version. Whether the
MCP framing uses an SDK or is hand-written is an implementation choice made in
ticket 05, not here.

**Six read-only tools.** The first four keep Wake's names and parameters minus
the prefix so prompts and habits transfer; the last two are vibebuddy's own.

| Tool | Reads |
| --- | --- |
| `vibebuddy_list_sessions` | most recently updated sessions; `project` (path or unique name), `agents`, `since`, `starred`, `limit` |
| `vibebuddy_search` | FTS over readable message text; each snippet carries `vibebuddy://session/<key>#<seq>` |
| `vibebuddy_get_session` | one transcript as compact Markdown with `[seq N]` markers, tool calls folded to a line, Meta and Thinking omitted unless asked; paged by `from_seq` |
| `vibebuddy_list_projects` | projects with indexed sessions, most recent first |
| `vibebuddy_get_summary` | the persisted conversation summary for a key with its style, provider, model, date, **coverage**, and whether the source changed since it was written; never generates one |
| `vibebuddy_live_status` | the daemon's current sessions for a project: three states, `waitKind`, control channel, agent, checkout directory, last activity |

Every answer states what it covers. A listing ends with the index-freshness
line; `get_session` opens with the source revision it read; `get_summary`
prints the summary's coverage statement and marks a summary whose source
revision moved as stale rather than hiding it.

**Keys and references.** A session key is `<agent>:<nativeSessionID>` with
agent one of `claude-code`, `codex`, `cursor`, `grok-build`. A reference is
`vibebuddy://session/<key>#<seq>` where `seq` is the message's position in the
readable dialogue for a given source revision. Keys carry the native id the
agents themselves report in hooks, transcripts and status lines, so a session
can be named without guessing.

**Sources in the first version: Claude Code, Codex, Cursor local transcripts,
Grok Build, each reporting its own coverage.** Claude and Codex are the existing
roots. Cursor adds the agent transcript that Cursor's hook documentation names
as `transcript_path`, already located and parsed by `CursorTranscripts`; it has
no tool results, and says so. **Grok Build is list/title-only in the first version.**
Ticket 07 obtained three official exports, but its protected TUI comparison did
not complete. The owner-defined downgrade therefore applies: enumerate local
rows with `grok sessions list`, publish no Grok messages or FTS rows, and return
"该来源无全文" from `show`. Grok's own search covers summaries and first prompts
only; its protected invocation failed in preflight and is not used here.
Official list dates have day precision and cannot stand in for transcript
revisions. Workspace directory metadata verifies the cwd of a local list row;
remote-only and unmatched sibling rows are excluded without guessing a project.
The process sandbox forbids file writes and child-process creation; time/output
limits bound the inventory, and queries never invoke it. `updates.jsonl` is not
a history source in this ticket; any future alternative needs separate scope
and authorization. No source claims the same fidelity as another;
the per-source capability table lives in `docs/session-history.md`. Excluded:
Cursor IDE chats (encrypted), Cursor cloud agents (ADR-0018), Copilot history
rows, Grok Bot.

**The index is shared and written by two parties under explicit coordination.**
The store stays at `SessionHistory/`. The Mac app refreshes it as today;
`vibebuddy-mcp index` refreshes it explicitly. Nothing else writes, and a
query never rebuilds or refreshes implicitly. Ticket 03 adds cross-process
write coordination (an exclusive lock around a refresh, atomic publication of
`index.json` and the content caches, a read-only open path for `search.sqlite`)
and defines what a reader sees during a refresh. Listing and reading need only
the atomically written JSON files and can ship first; search waits for that
ticket, because today the first query builds index rows. Headless `vibebuddyd`
does not gain the index.

**`live_status` is in the first version as an optional enhancement.** It is the
only tool that talks to the daemon and it only does `GET /snapshot`. When the
daemon is unreachable it answers "live status unknown", and every history tool
keeps working. It excludes the caller's own session when the caller can name it,
reports the checkout directory of each session, and its answer is a
collaboration hint: another agent being busy in the same checkout is something
to tell the user, not a rule that forces a worktree switch. The install token
is read from `TokenStore` to authenticate that request and appears in no
output, log or error text.

**Read-only is the contract.** No tool approves, denies, answers, steers, stops,
dispatches, stars, archives or deletes. Those stay on the phone and Mac routes
under ADR-0009. A test asserts that an existing store is byte-identical after
any tool call. "The CLI is for humans" is not an argument this ADR makes:
agents run shell commands too, so the CLI carries exactly the same read-only
tool set and nothing else.

**Relay is a handoff note that names its source session.** The `handoff`
discipline is adopted as a project skill with these fixed contents: goal,
decisions already made, authorization scope, current changes, verification
evidence, next steps; existing material referenced by path; unverified
judgements marked as such. Notes are saved under
`.scratch/<feature>/handoffs/` and referenced from the ticket; existing handoff
files are not migrated. The note opens with `Source session: <key>` holding the
**actual** session id of the writing session, taken from the agent's own
runtime (its hook envelope, status line, transcript path or session file); when
the writer cannot determine it, the line says `unknown`. "The most recent
session in this project" is never used to fill it, because parallel agents
would cross wires. The reader reads the handoff first, then `get_summary` and
`get_session` only for what the note does not settle; a summary is never
allowed to override a newer handoff. No background-launch or dispatch mechanism
is added for relay; starting the next agent stays a human action through the
existing entry points.

**Out of the first version:** cross-machine mirroring, the Mac App Store
edition (`docs/agents/mac-app-store.md`), Copilot history, any write path.
Acceptance is same-machine relay.

## Alternatives rejected

- **Treating this as an exit layer only.** The store is single-process today;
  exposing it without coordination would corrupt the index the Mac app relies on.
- **History over the daemon's HTTP routes.** LAN-reachable surface for data the
  phone does not need, requires the app running, and every target agent already
  speaks MCP over stdio.
- **Pointing agents at Wake's `wake.db`.** Different schema and lifecycle, not
  ours to keep working, and the user would need Wake running.
- **Write tools over MCP or CLI.** A model could approve its own tool call.
- **A relay-specific dispatch path.** Considered on 2026-09-13 and removed by
  the owner: it adds a write path to a read-only binary, and "CLI only" does
  not make it human-only.
- **Reverse-engineered `updates.jsonl` as the Grok history source.** An official
  enumerate-and-export interface exists. The first version applies its explicit
  list/title downgrade when the fidelity gate is not proved; reverse engineering
  is excluded from ticket 07.
- **Filling `Source session` from the newest session.** Wrong whenever two
  agents work in one project, which is the case the feature exists for.
- **A daemon-side lock on "who is working in this checkout".** The three states
  are observation, not scheduling; a missed hook would become a blocked agent.
- **Handoff notes in the OS temp directory.** They vanish between sessions and
  harnesses; project rules already place durable non-Git artifacts in `.scratch/`.

## Consequences

- Work order: (1) history reading and index consistency, including the two new
  sources; (2) the binary, tools and CLI; (3) packaging, skill, docs, glossary;
  (4) a real Claude Code to Codex relay on one machine as acceptance.
- `SessionHistoryAgent` grows `cursor` and `grokBuild`; the Mac History scope
  shows those conversations, a visible product change listed in acceptance.
- `CONTEXT.md` gains **Session key**, **History reference**, **Live status
  (tool)**, **Handoff note**. `docs/session-history.md` drops the future-work
  sentence and gains a per-source capability table and a Connect section.
- Tests: tool definitions stable; CLI and MCP print identical bytes; exit
  codes; store unchanged by any read; concurrent refresh and read do not
  corrupt or crash; key parsing accepts a full reference.
