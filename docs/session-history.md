# Mac local session history

The Dashboard has three library scopes: **Current tasks**, **History**, and
**Favorites**. Current tasks keeps the daemon's live state and actions. History
reads local Claude Code, Codex and Cursor conversation files independently; selecting or
searching an archive never inserts it into the live snapshot.

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

| Source | Readable content | Coverage limits |
| --- | --- | --- |
| Claude Code | User/assistant text, tool calls/results, available plaintext thinking | Child sessions excluded; attachment and resource-limit notices apply |
| Codex | User/assistant text, tool calls/results, available plaintext thinking and compaction | Encrypted reasoning is not decoded; attachment and resource-limit notices apply |
| Cursor local transcript | User/assistant text and tool call inputs | No tool results or thinking; no encrypted IDE database or cloud agents; transcript files do not identify IDE versus CLI provenance |

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

SSH history mirroring and MCP/CLI access are separate future work. This feature does
not install hooks, synchronize repositories or replace the running app. Mac App Store
sandbox acceptance is separate from this direct-distribution implementation.
