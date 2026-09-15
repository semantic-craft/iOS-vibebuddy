# ADR-0028: Phone Recap confirms a frozen set of recorded rounds

- Status: accepted
- Date: 2026-09-16
- Amends: the phone exclusion in ADR-0024; extends ADR-0027's navigation.

The phone exposes Recap from Inbox and global navigation using the existing
snapshot and exact completion/horizon APIs. The daemon owns the 24-hour window,
12-entry limit, ordering, failed entries and read state. List filters do not
change this window. Missing Recap support, an empty window and cached offline
entries remain distinct states. Watch Recap is not restored.

Selecting a row freezes its entry, source and pairing epoch. Its original body
is fetched by source/session/completion through CompletionBodyReader; unavailable
history never falls back to the current task's output. A separate View current
task action revalidates live authority and opens the phone reader. Browsing a
recorded round does not automatically mark it read. Manual read targets only
that exact completion; failed rounds have no completion read state.

An explicit confirmation freezes displayed entry IDs, completion requests and
the newest displayed endedAt as its horizon. The pure RecapConfirmation state
machine moves from MacCore into Kit and is shared by Mac and phone. Repeated taps
cannot replace a pending batch; retry sends only unresolved members of that
original batch. Accepted, already-read, stale and unavailable requests are
terminal; stale/unavailable members are disclosed as skipped. A transport failure
retains retry state. The horizon is sent only once all completion members are
terminal and never changes those members' reading state.

The phone owner retains a batch across navigation, checks source, pairing epoch,
connection generation and attempt identity around asynchronous operations, and
invalidates it after a known source or pairing change. Missing source pauses
confirmation. A fresh explicit batch can start after invalidation, including a
same-source re-pair. No read count or failed state is changed optimistically;
authoritative snapshots and individual receipts remain distinguishable.

No wire fields, ledger retention or history-pagination endpoints are added.
