# ADR-0035: Bounded offline Grok Bot notification inbox

- Status: accepted
- Date: 2026-10-11
- Supersedes ADR-0034's fresh-start, receipt-only and no-backfill policies

The owner requested restart recovery of unread notifications, persistent read
acknowledgements and one Japanese backlog announcement, without per-Bot reminders.
The notification-vs-task-terminal-state boundary in ADR-0034 is unchanged.

## Decision

Persist payload, account scope, read state and automatic-speech claims together in
one atomic owner-only inbox file. A committed pending payload is sufficient to
reconstruct a card after a crash. Read acknowledgements must persist before success
is reported; payload recovery does not depend on the lifecycle journal. Existing
receipt-only files migrate using known lifecycle read state; unknown legacy state
is a deduplication tombstone, never permission to resurrect or speak old content.

Persist the first enablement time per account. Restart and account re-selection
scan cached messages after that boundary and within seven days, with stable-ID
deduplication. Do not advance a timestamp cursor after each message: older messages
may synchronize late. The inbox is limited to 4096 records, returning backpressure
on storage failure or capacity exhaustion. The source cache's retention can be
shorter than seven days. Collector status reports retention and a possible gap
when preceding-cache timestamps overlap the recovery interval.

Restore unread cards quietly with original source timestamps. Suppress their
individual Mac notifications and speech; after a short settling interval claim all
unannounced recovered IDs atomically and enqueue one fixed Japanese count summary.
Respect quiet mode, summary/read-aloud switches and the voice-call gate. Manual
reading/replay remains available. Already announced unread cards can be restored
again without another automatic backlog summary. Marking unread does not rearm
speech. Account switches retire old cards without deleting account read state.

Audio is intentionally at-most-once automatically: a crash after the durable claim
but before playback may lose that audio, while the unread cards remain recoverable.
This is not an exactly-once audio transaction. Fixed count copy requires only TTS,
not a model-driven conversation sweep. New notifications continue ordinary Japanese
summary/read-aloud behavior.

## Verification boundary

Test the durable pending crash window, duplicate retries, read/restart/retry,
account filtering, retained enablement, multi-message single claims and malformed
storage. Exercise actual process restart, cached notifications arriving while the
collector is stopped, and native Japanese audio. Mac-wide offline synchronization,
unsynchronized conversations and upstream cache eviction cannot be promised by a
local inbox. This decision does not add a cloud event subscription or Bot routine.
