# Mac local session history

The Dashboard has three library scopes: **Current tasks**, **History**, and
**Favorites**. Current tasks keeps the daemon's live state and actions. History
reads local Claude Code and Codex conversation files independently; selecting or
searching an archive never inserts it into the live snapshot.

Open History to index `~/.claude/projects`, `~/.codex/sessions`, and
`~/.codex/archived_sessions`. `CLAUDE_CONFIG_DIR` and `CODEX_HOME` replace the
respective home directory. Project groups use the original full working directory;
matching basenames and worktrees are not merged. Claude child/sidechain transcripts
are excluded so their shared parent ID cannot replace the parent conversation.

Search matches message text, including Chinese and code substrings. Select a result
to highlight that message; matching tool messages expand. The reading pane shows
30 messages at a time, with Earlier/Later controls for context. Large source files
and individual messages have explicit resource limits; source notices and each
record's warnings identify incomplete or omitted content. Reasoning and images are
not rendered as full content. Search is substring-based, not semantic search.

The app checks sources on opening the library, on Refresh, and every 30 seconds
while the library is open. Initial indexing advances in bounded batches; pending
coverage is reported. The local index stores metadata and separate per-source text
caches under `~/Library/Application Support/VibeBuddy/SessionHistory`. Only selected
text is loaded for reading. Rebuild index re-reads the sources; favorites are saved
separately and retained. Missing sources retain their last indexed copy with an
unavailable label; they are not evidence of a finished or controllable task.

**Export Markdown** uses the system save panel. It includes source identity,
available user/assistant text, readable tool records and completeness warnings.
Cancelling does not create a file. Export and favorites do not modify source logs.
History is not automatically included in voice or completion-summary context.

For a uniquely matched live Session, history reuses the existing Jump and supported
Codex input actions, checking live identity again at the time of the action.
For a historical Claude conversation with a valid ID and existing project directory,
**Copy resume command** prepares a shell-quoted command for the user to run; copying
does not run it. Unknown Codex CLI/Desktop provenance is shown as unsupported rather
than opening a new task or typing into a terminal. Source visibility alone does not
establish approval or control capability.

SSH history mirroring and MCP/CLI access are separate future work. This feature does
not install hooks, synchronize repositories or replace the running app. Mac App Store
sandbox acceptance is separate from this direct-distribution implementation.
