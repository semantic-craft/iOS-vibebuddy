# Mac local session history

The Dashboard has three library scopes: **Current tasks**, **History**, and
**Favorites**. Current tasks keeps the daemon's live state and actions. History
reads local Claude Code, Codex and Cursor conversation files independently; selecting or
searching an archive never inserts it into the live snapshot.

Grok Build also appears as **list and title metadata only**, from its official
`grok sessions list` command. The first-version transcript fidelity gate did
not pass (three exports were readable, but zero of three protected TUI comparisons completed); `show 'grok-build:<id>'` reports that this source has no transcript.
No Grok messages or titles enter the full-text index. Search explicitly states
this coverage limit instead of treating the source as an index that needs repair.

| Source | Full-text source | Tool results | Thinking | Time and coverage |
| --- | --- | --- | --- | --- |
| Claude Code | Local conversation JSONL; validated cache or read-only source fallback | Available | Available plaintext; explicit show option | Record timestamps, then file mtime; child sessions excluded |
| Codex | Local and archived rollout JSONL; validated cache or read-only source fallback | Available | Available plaintext; encrypted reasoning not decoded | Record timestamps, then file mtime; attachment and resource-limit warnings |
| Cursor | Local agent-transcripts JSONL; validated cache or read-only source fallback | Unavailable; tool inputs are readable | Unavailable | Timestamp envelopes, then file mtime; files do not identify IDE versus CLI; no encrypted database/cloud content |
| Grok Build | Unavailable; official local list/title metadata only | Unavailable | Unavailable | Official list dates have day precision; remote-only rows excluded; no full-text search |

Grok workspace directory names under `$GROK_HOME/sessions` (default `~/.grok`)
locate candidate working directories. For long paths stored as slug-hash names,
the importer reads only standalone `summary.json` identity/cwd fields to locate
the workspace: summaries are capped at 64 KiB, symbolic links are skipped, IDs
must match their directories, and conflicting cwd values are rejected. It does
not read `updates.jsonl`. The shared executable resolver honors `$GROK_HOME/bin`,
standard installation locations and `PATH`, with `~/.local/bin/grok` retained
as a fallback for App launches whose `PATH` omits it.
Each local row must match a directory in that workspace, since official list
output may include sibling worktrees or remote sessions without their absolute
working directories. Unmatched or malformed rows are omitted with a coverage
notice. Missing working directories and command time/output limits also produce
partial-coverage notices; existing metadata is retained as unavailable.

Only the App's locked refresh or explicit `vibebuddy-mcp index --rebuild` runs
the inventory command. Queries read cached metadata and never launch Grok.
The command runs through the macOS process sandbox with file writes and child
process creation denied, a three-second per-workspace timeout, a 15-second scan
budget and a 1 MiB combined output limit. If that protection is unavailable or
the command fails, no unprotected retry occurs and no leader is started.
List-row revisions fingerprint metadata; they are not transcript revisions and
cannot detect unchanged titles after dialogue changes on the same day.

**Copy resume command** can prepare `grok --resume <id>` for an available local
row with a valid native UUID and working directory. Copying does not run it.
The History agent filter includes Grok Build; Demo uses an in-memory Grok metadata
sample and does not scan user history, generate summaries or contact providers.

Open History to index `~/.claude/projects`, `~/.codex/sessions`, and
`~/.codex/archived_sessions`, and Cursor agent transcripts under
`~/.cursor/projects/*/agent-transcripts`. `CLAUDE_CONFIG_DIR` and `CODEX_HOME` replace the
respective home directory. `VIBEBUDDY_CURSOR_HOME` is a process-only vibebuddy override
for the Cursor source home; it does not configure Cursor itself. Project groups use the original full working directory;
matching basenames and worktrees are not merged. Claude child/sidechain transcripts
are excluded so their shared parent ID cannot replace the parent conversation.

Cursor discovery accepts `<id>/<id>.jsonl` and the older flat `<id>.jsonl` layout.
It resolves the flattened project directory against existing directories, leaving an
unknown project explicit. It never reads Cursor's `state.vscdb`. Parsed timestamp
envelopes determine conversation time; source mtime is the fallback. Error and
aborted turn endings remain visible warnings. Agent-prefixed IDs keep the same
native ID from different agents separate. Multiple available files for one key
remain ambiguous for CLI transcript reads and search references.


Cursor is available in the Mac History agent filter and in `sessions --agent cursor`,
`search QUERY --agent cursor`, and `show 'cursor:<composer id>'`. Read-only output
states the source's coverage. The transcript adapter preserves full readable text
within the same 32 MiB source / 128 KiB message limits as the other sources.

Search matches literal message text, including Chinese and code substrings. A local
SQLite FTS5 trigram index handles queries of three or more characters; shorter
queries scan the indexed text without reopening every transcript cache. Agent,
project, favorite and archive filters apply consistently to the result list. Select a result
to highlight that message; matching tool messages expand. The reading pane shows
30 messages at a time, with Earlier/Later controls for context. Large source files
and individual messages have explicit resource limits; source notices and each
record's warnings identify incomplete or omitted content. Search is substring-based,
not semantic search.

The reader projects raw records into dialogue: user messages are right-aligned
bubbles; assistant replies render Markdown headings, lists, tables and fenced code
with copy actions. Tool calls are grouped with parameter previews, invocation counts
and explicit source error flags; results are paired by call ID. Tool details show
600-character previews and copy the full indexed field. Plaintext Thinking can be
expanded when attached to dialogue or tools; thinking-only intermediate rows and
injected Meta context are hidden from ordinary reading. An explicit search hit can
reveal either without losing its original message identity. Context compaction is a
centered marker. Encrypted reasoning is not decoded; image attachments remain
placeholders. There is no syntax-coloring guarantee.

The app checks sources on opening the library, on Refresh, and every 30 seconds
while the library is open. Initial indexing advances in bounded batches; pending
coverage is reported. The local index stores metadata and separate per-source text
caches under `~/Library/Application Support/VibeBuddy/SessionHistory`. Selected text is loaded for reading; refresh eagerly builds message indexes.
Queries open SQLite read-only and omit rows whose source revision differs from
the loaded metadata. An exclusive `.refresh.lock` coordinates App and CLI refreshes;
an App refresh skips a busy writer and reports the reason. JSON files publish
atomically, and SQLite publishes each source in a transaction. Readers see complete
files and committed matching message revisions, without waiting for the full scan.
`vibebuddy-mcp index` builds an absent index; `index --rebuild` refreshes all sources.
The explicit command exits 2 when another refresh holds the lock. Conversation timestamps drive
list order, with file timestamps as a fallback. Agent-injected setup blocks remain
searchable but are excluded when deriving titles. Rebuild index re-reads the sources; favorites, pins and library archives are saved
separately and retained. Missing sources retain their last indexed copy with an
unavailable label; they are not evidence of a finished or controllable task.

**Pin** keeps a conversation above other history rows. **Archive in library** and
**Unarchive in library** organize the library without changing original files or
live tasks. The archive filter distinguishes unarchived and archived records.
**Archived in Codex** identifies native source archive state; removing a library
archive cannot undo that native state. Use Codex to unarchive the original task.

**Export Markdown** uses the system save panel. It includes source identity,
available user/assistant text, readable tool records and completeness warnings.
Cancelling does not create a file. Export and favorites do not modify source logs.
History is not automatically included in voice or completion-summary context.

**Generate summary** explicitly sends the selected conversation's readable records
to the provider/text model configured for summaries in Settings, using its existing
BYO key. This request is independent of the automatic completion-notice switch.
The summary covers goals, decisions, results/verification and open work. Meta and
Thinking are excluded; source-provided compaction summaries may supply earlier
context. Material keeps the first request and recent records within a 48,000-character
budget, with per-record excerpts and a visible coverage statement. It does not claim
to read omitted source content. A request can be cancelled, has a 60-second timeout
and is not automatically retried.

Generated summaries persist locally with provider, model, date and source revision.
Source changes mark them out of date; Regenerate updates them on request. Switching
conversations cancels the pending request and prevents late results from replacing
the newly selected conversation. This reading aid does not establish completion,
generate a notification or alter the live session state.

For a uniquely matched live Session, history reuses the existing Jump and supported
Codex input actions, checking live identity again at the time of the action.
Matching requires the same agent and native session ID. A known terminal directory
must match; a Codex daemon/Desktop session without a terminal can instead match its
explicit live thread ID. Duplicate matches remain unavailable, and this match does
not grant CLI provenance or bypass the live session's action capability checks.
For a historical Claude conversation with a valid ID and existing project directory,
**Copy resume command** prepares a shell-quoted command for the user to run; copying
does not run it. An available, unarchived Codex record with explicit `source=cli` metadata also
provides a quoted `codex resume` command. Unknown, Desktop and subagent provenance
is shown as unsupported rather than opening a new task or typing into a terminal.
A local Cursor record with a valid ID and existing project directory offers
`cursor-agent --resume <id>` for copying when the Cursor CLI is available. Copying
never executes the command or claims that the CLI is signed in. Source visibility alone does not
establish approval or control capability.

## Connect an agent

Settings → Connect shows the bundled `vibebuddy-mcp` path and copyable Claude Code,
Codex and Cursor connection snippets. The CLI `setup` prints the same instructions;
neither surface installs software or edits configuration. See
[connection instructions](getting-started.md#connect-an-agent-to-local-history).
One binary runs stdio MCP without arguments and CLI subcommands with arguments.
Both expose the same read-only queries:

| CLI | MCP tool |
| --- | --- |
| `sessions` | `vibebuddy_list_sessions` |
| `projects` | `vibebuddy_list_projects` |
| `search` | `vibebuddy_search` |
| `show` | `vibebuddy_get_session` |
| `summary` | `vibebuddy_get_summary` |
| `status` | `vibebuddy_live_status` |
| `facts` | `vibebuddy_handoff_facts` |

Quote Session keys and History references: `summary 'codex:<id>'` and
`show 'vibebuddy://session/codex:<id>#12'`. Sequence numbers are one-based within the reported source
revision, including hidden Thinking records. CLI/MCP search omits Meta and Thinking;
show always omits Meta and includes Thinking only with `--thinking`.
The App reader's explicit-search reveal behavior is separate.

Summary reads only an existing saved summary, including coverage and stale status;
absence is a normal result. Read the newest handoff first, then its source summary,
and read transcript records only for unresolved questions. A summary cannot replace
a newer handoff or establish current authorization, completion or verification.

Queries never refresh or lazily populate the index. A stale transcript cache is
replaced in memory by a read-only parse of the source, without writing it back.
Show and summary can resolve supported source files even without an index. List and
search report a missing index with instructions to open History or explicitly run
`vibebuddy-mcp index`; `index --rebuild` is separate maintenance, absent from MCP.
Search uses only committed matching revisions and reports incomplete coverage.

Facts prints, for one Session key, the header lines a handoff note starts with
and a Facts section from the Mac's lifecycle journal and tool ledger (seven days;
`~/Library/Application Support/vibebuddy/`), plus a read-only git probe of the
checkout (`--cwd`, else derived from the files the session edited). It lists at
most `--commands N` (default 20, max 50) commands with exit codes, states per
source what could be observed (hooks and the Codex app-server carry commands and
exit codes; Cursor ACP and the rollout tailer carry tool names only), and ends
with a data-freshness line. It never writes, never opens the daemon, and never
chooses a session: a bare native id resolves only when one agent recorded it,
and "Not recorded" is a normal exit-0 answer. A session the Mac started through
Continue with… gets a `- Continues: <source key> (started by the Mac from …)`
line from `continuations.json` as soon as the dispatch recorded it. See
ADR-0023 and its 2026-09-14 amendment.

Status reads the authenticated daemon snapshot, excludes a supplied real caller
native ID (`status --exclude-session '<own-native-thread-id>'`), and groups by checkout directory.
Another busy session is a collaboration hint for the user's decision, not a lock.
An unreachable daemon produces unknown and exits 0. Status does not start a daemon
or automatically change checkout; older daemons may lack checkout information.

This feature does not install hooks, synchronize repositories or replace the
running app. Cross-machine history mirroring and Mac App Store sandbox acceptance
are outside this first version.

Handoff facts use the agent identity captured with each tool call. Calls whose
agent was not recorded are omitted with a coverage explanation; the requested
session-key prefix never supplies missing provenance. Only confirmed successful
edits contribute to Files edited, inferred checkout paths, and ticket candidates.
