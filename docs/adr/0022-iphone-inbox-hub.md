# ADR-0022: The iPhone home is an inbox hub

- Status: accepted
- Date: 2026-09-13
- Amends: ADR-0014 (the iPhone dashboard is no longer one flat list at the
  root; the list is one level down); ADR-0021 §1 (the wrist's alert and
  result order now comes from the shared pending queue). ADR-0017's tokens,
  ADR-0020's reading rules and ADR-0012's notification identities stand.
- Source: `.scratch/iphone-board/PRD.md` and its tickets 01–07; prototypes in
  `.scratch/iphone-board/design/`.

## Context

The owner runs several agents at once, almost always in YOLO mode, so the
phone rarely has an approval to give. Away from the Mac its job is to answer
three questions fast: how many things wait for me, which one first, and what
comes next once that one is handled. The flat list of ADR-0014 answered none
of them directly: rows were grouped by state, but "which first" was implied
by group order and the reader had to scroll to see the shape of the day.

The owner asked for Cursor's iOS app as the reference and supplied two
screenshots of it on 2026-09-13: a home that is a hub (four bucket tiles, a
workspace list, one composer) and a bucket page that is a plain list (a big
title, a Recents group, then the same rows under their projects, two lines
per row, no inline keys). The owner then settled the open choices: the
fourth tile is Working, reading aloud covers stuck sessions and unread
results, and "Next" follows the scope the reader entered from.

## Decision

1. **The home is an inbox hub.** Title, the snapshot's mood line, a **First
   up** row, four **bucket** tiles — All sessions, Unread results, Needs you
   (worded *Stuck* while it holds only confirmed failures), Working — a
   **Projects** list, and the composer. Every count is
   `TaskPresentationSummary` over current sessions (`SessionCurrency`), the
   same numbers the Mac panel and the Watch say. A project's number is its
   share of the pending queue; projects with pending work lead, in queue
   order, then the rest by latest activity. Read results have no tile: they
   are reached through All sessions. No current sessions → the `moon.zzz`
   empty state with "Show N older".
2. **First up is the head of the pending queue** — `PendingTasks.ordered`
   over every current session, so it is the same task the Watch's first card
   shows and the first thing the phone reads aloud. Tapping it opens the
   detail; the read happens there, by ADR-0020's rules, never on the hub.
3. **A bucket or project opens the list page**: back, search and Customize
   circles; the scope's name as the title; a Recents group and then the same
   rows under their projects (from a project row, that project alone). A row
   is the dot, the title, the time, and one line — the state word in its
   colour, one fact (`+41 −12`, a step, the question or result), the project.
   No inline approve, answer or reply keys: the detail decides, the swipe
   follows or mutes. Search matches title, project and branch and is cleared
   on leaving. Collapse state resets on entry.
4. **Next follows the scope entered from.** From First up, the detail's
   "Next" walks the global queue; from a bucket or project, that scope. The
   footer names the scope and the position (`All sessions · 2 / 5`). The
   mood line and the tile counts stay global whatever the scope.
5. **One queue on every surface.** The Watch projection orders its alerts
   and its results by the same `PendingTasks.ordered`, so the wrist's cards
   are a subsequence of the phone's queue. The rule itself did not move:
   questions and plan decisions, then approvals, then confirmed failures,
   then unread results, newest first within each.
6. **Reading aloud on the phone.** "Read pending" speaks the queue in order
   through the Kit's `CompletionSpeechQueue` and `AnnouncementCopy`: stuck
   sessions and waits first, then unread results; ten at most, each item
   bound to its round and re-checked before it is spoken; pause, skip,
   replay, stop. Speech comes from the voice companion's provider when it
   has a key, otherwise from the system voice. Reading, skipping and
   finishing never mark a result read. A live voice call pauses reading and
   does not resume it. Automatic background reading stays the Mac's job:
   the phone only reads when asked.
7. **The voice page** shows the read-aloud queue and the conversation on one
   screen with pause, mic and skip at the foot, and says which side the
   microphone is on (ADR-0004). Two voice tools join approve, deny and
   answer: `mark_read_session` confirms the displayed round as read — never
   reviewed or accepted — and `instruct_session` sends free text to a
   running or finished session as the composer would. Both report the
   application's receipt, which is not the agent's completion.

## Consequences

- ADR-0014's list survives as the bucket page; its 24-hour window, "Show N
  older" and Customize are unchanged. Its inline approval block and question
  card left the rows; the detail's decision section carries them.
- ADR-0021's home order is now derived, not local: the Watch demo scenarios
  were realigned (two approvals in the permission scenario; the open
  question is the newer wait in the question scenario) because a question
  outranks an approval on every surface.
- `DashboardFilters` gained a bucket and a query; `InboxProjection`,
  `PhoneAnnouncer` and `VoicePageView` are new phone files; the Kit's
  `VoiceAction` gained two cases. The Mac now binds read and instruction actions
  to the source, Session and round actually returned by status; dispatch uses
  existing answer/steer/continue channels. A transport receipt is not completion,
  and an unknown result is not automatically resent.
- The Chinese tables carry every new string; screenshots and the Demo page
  hooks (`VIBEBUDDY_DEMO_PAGE=bucket/<id>|project/<name>|list|read|voice`)
  are the acceptance evidence, with real-device reading and a real daemon's
  three-surface comparison left to ticket 06.

## Amendment: Mac Inbox (2026-09-14)

The Mac Dashboard now opens on Inbox: First up, the four current-session
buckets, the shared Recap overview and Projects with pending counts. All
sessions opens the existing list/detail workspace. Recap was removed on every device on 2026-09-26
(ADR-0028 amendment). History and Favorites
retain their library counts. New task remains available. Inbox global counts
ignore residual list filters; projects preserve their original identity, including
full paths or cloud repository identity when supplied by the live source.
The lifecycle journal intentionally stores only project basenames; restored
sessions without checkout metadata use that limited identity until a live source
supplies it again. Inbox does not persist or reconstruct missing full paths.
The detail Next footer retains its
explicit scope and selection when a result becomes read.
The menu and Glance navigate to this same workspace using Session identity.

## Content presentation and phone reading (2026-09-15)

Read pending now requests a complete, purpose-specific presentation from the
paired Mac before synthesizing speech. The source Mac owns the global content
style; the phone owns its voice, announcer style and optional system voice.
Source, connection generation, exact round and effective content revision must
still match when the response arrives and before playback. Replaying the latest
announcement repeats its original text and is labelled as such. It does not
silently regenerate under a new preference. No read-aloud action acknowledges a
result or grants permission. Plain fallback remains available without a model.
