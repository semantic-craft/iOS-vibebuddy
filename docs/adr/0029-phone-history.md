# ADR-0029: Authenticated phone transcript pages

- Status: accepted
- Date: 2026-09-16
- Extends ADR-0019 and ADR-0024 without changing result acknowledgement.

The phone requests `/history` under the existing bearer middleware, using the
connected snapshot source ID and exact native key. `HistoryIdentity` shares
`SessionReaderSource` mapping with the phone. Titles and client paths never
select files. The repository retains root, ambiguity and in-file identity checks.

Each request uses a fresh read-only repository with an empty cache location.
There is no index refresh/write or full-library content parsing. Native filename
enumeration still costs time on each request. The adapter permits one in-flight
parse, returning 429 to other callers. It does not reuse the mtime/size cache.

`raw-visible-v1` sends existing parser message fields, excluding meta/thinking.
Revision hashes source, key, projection, parser revision, messages and warnings.
Dates retain Foundation Codable semantics. A server-held cursor binds source,
key, revision and the next exclusive end offset, expires after 300 seconds and
is bounded to 256 entries. Offsets are not MCP sequence references. Pages default
to 30 messages, allow 1–100, and fit 1 MiB; a single oversized message is rejected.
A parser behavior change affecting this projection must bump parserRevision.

The parser reads the first 32 MiB, not the actual tail of an oversized source.
The phone prominently identifies this limit and missing later content. Partial
warnings and Cursor local-only coverage remain visible. Unsupported or unavailable
history can show the existing exact-session recent excerpt, explicitly labelled.
No claim of arbitrary-length complete history or thinking coverage is made.

The phone holds one request and one in-memory chain per selected source/session.
Source or pairing epoch changes invalidate requests. A changed/expired revision
stops earlier paging; loaded text remains labelled until an explicit updated page
replaces it. New pages never splice across revisions. Earlier pages preserve the
current scroll identity. Offline display is only already-loaded in-memory text,
not a persisted cache. There is no background full transcript polling.

History push obscures the result reader. History fetch, scroll, tool expansion
and copy do not acknowledge results or grant control. The existing result card
alone retains its exact completion and visibility checks.

The preceding contract spike measured Release on fixed real sources within
6 seconds/request, 512 MiB RSS and 1 MiB payload. These are regression budgets,
not a production SLA. This implementation requires its own route, client and
native checks; earlier spike results do not count as its tests.
