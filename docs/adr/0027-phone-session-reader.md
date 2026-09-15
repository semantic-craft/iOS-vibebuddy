# ADR-0027: Phone tasks open in a full-height reader

- Status: accepted
- Date: 2026-09-16
- Amends: ADR-0022's phone detail presentation and ADR-0024's phone exclusion.

The owner selected a NavigationStack push for the phone reader. Opening a task
preserves its Inbox or filtered list underneath. Next replaces the reader's
selection within that scope and stops when no unvisited pending identity remains.
Reading removes pending results without closing the selected task or rebuilding
the list. Navigation destinations do not stop the dashboard connection.

The reader retains CompletionBodyReader and exact source/session/completion
requests. Selectable Text renders the original response; Copy result copies that
same text. This version adds no Markdown dependency. Activity, bounded recent
output and workspace changes remain separate from the authoritative result.
Only foreground, unobscured visibility of the current completion body may confirm
it automatically. iOS 17 retains explicit read controls. Old notifications do not
authorize the current round's dock or automatic read.

Approval/question controls and the current task composer occupy a bounded dock
above the keyboard; New task remains available in the navigation bar. Drafts are
owned above the reader, scoped to source, pairing epoch and session, and capture
the waiting/action identity. A changed identity preserves the old draft and
requires explicit discard. Successful responses only clear unchanged drafts;
failed or uncertain sends retain them. No transcript or displayed text grants
new action authority; DashboardStore revalidates each live action. Reader actions,
Next and Changes also check the source and pairing epoch frozen at opening,
including inside asynchronous send callbacks. New task remains independently
available after that authority expires.

This phone reader does not add Mac transcript indexing or history pagination.
Native app acceptance must cover push/pop, long text and raw copying, keyboard
and large text, visibility reads, and stale/offline draft handling. An isolated
renderer prototype is evidence only for that prototype.
