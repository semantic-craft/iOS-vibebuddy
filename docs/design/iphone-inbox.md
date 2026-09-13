# iPhone inbox

The phone's structure since 2026-09-13 (ADR-0022). Prototypes: the design
canvas linked from `.scratch/iphone-board/PRD.md`; artboard sources in
`.scratch/iphone-board/design/`; simulator screenshots in
`.scratch/iphone-board/shots/`.

## Three levels

1. **Inbox** (`InboxHomeView`, `InboxProjection`) — toolbar (connection circle,
   quota, Settings), title and mood line, **First up**, four bucket tiles
   (2 × 2, 104 pt, `bg3` on hairline, radius 12), **Projects** rows (folder
   glyph, name, pending count in `accentText`, chevron), composer.
2. **Bucket page** (`DashboardView` with `page == .list`) — back, search and
   Customize circles; the scope's name at 30/semibold; the mood line; an
   optional search field (36 pt, radius 10); *Recents* then per-project groups
   (`DashboardGrouping.recent`); rows of `TaskRow`: dot, title 16/regular,
   time, then `state word · fact · project` at 13 in `ink3` with the state
   word in its colour. The composer's ground fades in over 28 pt.
3. **Detail** (`SessionDetailSheet`) — unchanged order (goal, progress or
   result, decision, actions, evidence); the footer names the scope and the
   queue position, then *Next pending*.

Over the composer, two strips can stack: the read-aloud strip
(`AnnouncerStrip`: title, `n / N`, pause, skip, replay, stop) and the voice
strip; tapping the voice strip opens the **voice page** (`VoicePageView`).

## Taken from Cursor iOS, and deliberately not

Taken: the hub with four buckets and a workspace list; the bucket page's
title, Recents-then-projects grouping, two-line rows without keys; the
composer's placement and the circles-over-the-page toolbar.

Not taken: Cursor's PR / Review pages, Design Mode, Remote Control and its
`ACTIVE / IDLE / ARCHIVED` statuses. Our buckets are the three states plus
unread results, the row's second line is the state word and one fact rather
than a PR status, and every list is cut by `SessionCurrency`.

## Rules that hold everywhere

- Counts come from one `TaskPresentationSummary` over current sessions.
- Order comes from one `PendingTasks.ordered`; the Watch is a subsequence.
- Reading aloud, skipping, replaying and opening the hub never mark read.
- New controls use the Kit tokens and `PhoneChrome`; nothing here has its
  own colours, shadows or fonts.

## QA hooks

`VIBEBUDDY_DEMO=1 VIBEBUDDY_SKIP_NOTIFICATIONS=1` with
`VIBEBUDDY_DEMO_PAGE=` `bucket/<all|unreadResults|needsYou|working>`,
`project/<name>`, `list`, `read` (starts a read-aloud run), `voice` (reads
and opens the voice page), `task/<title>`, `customize`, `usage`, `newtask`.
Launch through `simctl` with the `SIMCTL_CHILD_` prefix and screenshot with
`simctl io`; reboot the simulator first if a test run left a permission alert
on screen.
