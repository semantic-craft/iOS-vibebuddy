# ADR-0026: Update history indexes from directory events

- Status: accepted; superseded 2026-09-23 (History archive removed, see amendment)
- Date: 2026-09-16
- Complements: ADR-0019 and ADR-0024.

## Context

History already has a SQLite message index and per-source transcript caches.
The dashboard refreshes it every 30 seconds. That skips parsing unchanged
transcripts but still enumerates all source roots and validates all index rows.
A single changed transcript therefore incurs work proportional to the library.

## Decision

The dashboard owns one explicit observation lifetime. A core FSEvents watcher
reports file paths and reconciliation requests. It merges events for 800 ms,
schedules a flush no later than two seconds after the first event, and caps
the queued path set at 4,096. A busy system can delay callback execution. Ordinary file changes call the repository's changed-path refresh.
The repository remains a passive actor. Read-only and CLI instances do not
start observers.

Incremental refresh uses the existing cross-process writer lock and parsing
budget. It reuses the same source parser, transcript cache and SQLite writer
as full refresh. It processes changed and deferred files without enumerating
all roots, checking every FTS row, or invoking Grok's inventory command.
Metadata reload checks the atomically published index file's identity before
reusing memory. Organization files remain independent.

Initial, manual and 30-second refreshes remain full reconciliation. Directory
structure changes, dropped events and queue overflow also request it. Concrete
file hints survive reconciliation and run afterward. Lock contention retains
the batch for retry. A parse-budget remainder continues without waiting for
another file event. Source read failures remain visible and retry on another
event or reconciliation, rather than looping continuously.

Only configured transcript roots are watched. Missing roots are checked for
reappearance without observing the user's whole home. A root replacement
restarts its stream. Closing or superseding the dashboard observation stops
delivery, and results from an older observation cannot overwrite the new one.

New source revisions include device, inode, size, modification time and change
time. This detects replacements that preserve size and modification time.
The revision uses the existing cache field; existing cache files remain
readable. Full reconciliation upgrades old source revisions within its parsing
budget. Legacy search and summary revision checks retain their prior semantics
until their records are updated.

## Consequences

The selected transcript watcher and independent read-only reader in ADR-0024
remain. Index events do not imply live state, completion acknowledgement or
permission to resume an agent. Original transcripts and organization metadata
are not deleted when a source disappears; its retained record becomes
unavailable.

Metadata JSON publication and snapshot sorting still scale with library size.
This change reduces routine source discovery and parsing work; it does not
make all history operations constant-time. It also does not implement partial
JSONL parsing or move metadata into SQLite. The fallback interval remains
unchanged so observer rollout does not also alter recovery latency.

## Verification

Check real filesystem delivery, replacement and root recovery separately from
synthetic dropped-event tests. Compare changed-path updates with full refresh
for snapshot and search parity. Exercise the native dashboard with isolated
copies of real agent data, including update while a writer lock is occupied.
Record workload and build configuration with performance measurements.

## Amendment (2026-09-23): History archive removed

Superseded. The History index this ADR kept current no longer exists (see
ADR-0019's amendment of the same date): the FSEvents history watcher, the
changed-path refresh, the re-index throttle and the 30-second reconciliation
are deleted, and with them the steady CPU and disk cost they carried. The
Mac app removes the old `SessionHistory/` cache once at launch.

What remains: ADR-0024's selected-transcript watcher (`TranscriptFileWatcher`)
for the one session the reading pane shows, and the filesystem revision
(device, inode, size, modification and change time) that the transcript
reader uses to decide whether to re-parse.
