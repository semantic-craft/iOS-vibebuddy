# ADR-0028: Phone Recap confirms a frozen set of recorded rounds

- Status: accepted 2026-09-16; superseded 2026-09-26 (Recap removed on every device). The original decision is in git history; only the removal record is kept here.

## Amendment (2026-09-26): Recap removed

Superseded. The owner found Recap unused, so it is deleted on Mac, iPhone and
Watch: the Mac's recorded ended rounds and recap horizon, the snapshot's
`recap` field, `POST /recap-read`, the recap presentation purpose, the shared
`RecapConfirmation` state machine, and the Recap pages, Inbox rows, sidebar
row and menu footer control. Unread results, *All sessions*, exact-round
`/acknowledge` and the phone reader are unchanged.

The verified completion result index that lived in the recap file stays: it
moved to `CompletionResultLedger` (`completion-results.json`) with the same
seven-day, 512-record, 8 MiB bounds. On first launch the Mac copies the
index out of the old `recap-ledger.json` and deletes that file.
