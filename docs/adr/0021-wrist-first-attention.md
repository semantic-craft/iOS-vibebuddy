# ADR-0021: The Watch is a reminder entry, not a dashboard

- Status: accepted
- Date: 2026-09-13
- Amends: the *Completion reminder* term in `CONTEXT.md` (fixed five-minute
  cadence, twelve at most → backing-off cadence, four at most); ADR-0017 §5
  (the Watch's counts are no longer a table on the home); ADR-0012 stands
  (the Watch still schedules nothing of its own).

## Context

The owner runs several coding agents at once and wants to know, away from the
Mac, which of them need them and to keep the work moving with as few taps as
possible. The Apple Watch is to be one of the main places that reminder lands.
The wrist's job, in the owner's words: *remind me → tell me why → let me
handle it → confirm what happened*.

The Watch companion already carried most of the machinery (ADR-0012, the
`WatchSessionAction` contract, `WatchConnection`, `WatchHapticTransitions`):
the iPhone projects a compact state over WatchConnectivity's application
context, the card can approve, deny, answer (one string or one pick per
question) and stop, every send reports `sending / accepted / failed / unknown /
refused`, and a late tap is refused by the phone's gate. A review against the
owner's direction on 2026-09-13 found four gaps, all in what the wrist is
*shown* rather than in what it can do:

1. The home did not answer "how many things need me, and which first". Under
   the top card sat a three-line counts table; the other waiting sessions were
   on a separate page whose rows could not be opened, so a second approval
   could only be reached by resolving the first. A session that stopped on an
   error was a number and nothing else.
2. A finished result reached the wrist only for a `followed` session. An
   ordinary session's unread completion was a count; it could not be read or
   marked read from the wrist.
3. Tapping a mirrored notification opened the app on whatever the home led
   with, not on the session the buzz was about.
4. A followed completion was re-announced every five minutes, twelve times.
   Mirrored to the wrist, that is twelve buzzes in an hour for one result —
   and the wrist is where that follow is most often earned, because
   approving from the Watch marks the session followed for ten minutes.

Apple's rules were re-read from the DocC sources on 2026-09-13 and bound what
can be promised. A local or remote notification sent to the iPhone appears on
exactly one device: the phone when it is unlocked with the screen on,
otherwise the worn and unlocked Watch, otherwise the phone. `updateApplicationContext`
is a latest-value mailbox delivered while the counterpart is not running; a
forwarded notification's *action* is answered by the app that posted it; the
default tap opens the watchOS app. `WKInterfaceDevice.play` does nothing in the
background outside a workout session, so an in-app haptic can never be the
background reminder — only the mirrored notification's own short look can.
`sendMessage` from the Watch wakes the iPhone app in the background, which is
what lets a wrist action travel while the phone is in a pocket.

## Decision

1. **The home reads top-down in attention order, and every row opens.** A
   headline (`CompanionCopy.moodLine`, the shared "N things need you") and the
   top alert's card first; then *Also waiting* — every other alert and every
   session that stopped on an error; then *Results* — unread completions; then
   *Followed* — followed sessions not already listed, which in practice are the
   running ones; then the quota strips and the freshness footer. Each row
   opens the same detail the card sits on, so the second approval is one tap
   away. The counts table is gone; the counts live in the headline's rest
   line. The mood line, the rest line and every list are computed over current
   sessions (ADR-0017 / `SessionCurrency`), as on every other surface.
2. **`results` joins the projection.** `WatchDashboardState.results` carries,
   for every current session that is not muted, the ones that ended badly
   (`error`) and the unread completions, newest first, at most six. They are
   `WatchFollowedTask`s, so the existing exact-round read
   (`WatchCompletionQueue` → `WatchCompletionRequest` → `/completion/read`)
   marks a result read from the wrist whether or not it is followed, and the
   Mac's reminder and every other device's badge stop together. The field is
   optional on the wire so an older relay or cache still decodes. The
   complication is unchanged: it keeps reading `followedTasks`.
3. **A notification tap opens its session.** The Watch app registers a
   `UNUserNotificationCenterDelegate` at launch (`WatchAppDelegate`), reads the
   session id from the mirrored notification's `userInfo` — the same key both
   channels already put there — and opens that session's detail through
   `WatchStateStore.openSession`, holding the id only until a relay supplies
   the source and pairing. A target absent from that projection opens an unavailable page; changing
   the pairing or navigating elsewhere cancels a pending cold-start target.
   Only the default action is handled here; Approve / Deny / Reply on a
   forwarded notification are answered by the iPhone, as Apple routes them. A
   notification arriving while the app is on screen is not presented on top
   of it: the store taps out the boundary itself.
4. **Viewing stays viewing.** Opening a wait from the wrist tells the Mac the
   request was *seen* (`WaitReadRequest`, so the missed-wait clock stops) and
   nothing more; opening a result queues the *read* of that exact round. The
   card's buttons are the only way to approve, deny or answer, and their
   sentences never say "approved" or "answered" — the alert leaves the screen
   when the next snapshot says the world changed. A session absent from the
   bounded projection opens an explicit unavailable page, never a live card. A result already opened stays readable after its
   row disappears, without retaining controls. Missing rows do not cancel
   offline read retries: only a newer observed round, a changed source/pairing
   or the daemon's exact-round outcome retires them.
5. **Completion reminders back off.** `CompletionReminderSchedule` re-issues
   the `agentDone` cue for a followed, unread completion after 5, 10, 20 and
   then 40 minutes — four reminders, the last 75 minutes after the completion —
   instead of every 5 minutes twelve times. The first reminder is as quick as
   before, the coverage still exceeds an hour, and the interruptions drop by
   two thirds. Everything else about the reminder is unchanged: same
   notification identity and collapse id, stopped by any acknowledgement,
   restarted by a new completion, a suppressed reminder spends no slot.

## Alternatives rejected

- **A Watch push token of its own.** Apple lets a dependent watchOS app
  receive APNs directly, but the companion already gets every iPhone
  notification forwarded by the system's own routing, and a second token means
  a second registry, a second collapse rule and a second place for ADR-0012's
  one-banner guarantee to break. Nothing the owner asked for needs the Watch
  to be reachable when the iPhone is not.
- **Critical Alerts or a Watch-side scheduler.** Rejected on the same grounds
  as before: the wrist may not bypass Focus, and a second scheduler is a
  duplicate by construction (`WaitingNotificationLedger`).
- **A results list keyed by attention.** Listing only followed completions is
  what the wrist already did, and it is the gap. Muted sessions are the one
  exclusion, matching `DeliveryMatrix`, which drops their completion cue.
- **Keeping the fixed five-minute cadence and muting it on the wrist.** The
  wrist cannot mute a mirrored notification selectively, and a reminder that
  reaches the phone but not the wrist would contradict "one on the phone is
  one on the wrist" (ADR-0012). The cadence is a Mac policy and was changed
  there.

## Consequences

- `CONTEXT.md`'s *Completion reminder* term is amended; ticket 06 of
  `mobile-watch-task-control` ("follow 保持固定 5 分钟、最多 12 次") is
  superseded on that one point by the owner's 2026-09-13 direction.
- The Watch's *Waiting* page survives for the many-alerts case, with rows that
  open; the home's "N more waiting" line is replaced by the rows themselves.
- `WatchDemoScenario.normal` now rehearses a result and a stopped session on
  the home without any change to its sessions.
- What a simulator cannot prove stays listed in the ticket: the mirrored
  notification's short-look haptic, the default-tap routing into the session,
  and the reminder cadence as felt on a wrist all need a paired device.

## Amendment: explicit result reading and count-only nonfollowed completions (2026-09-13)

The owner authorized the mobile/Watch tickets and selected a count with an iPhone
destination for completion-unread sessions outside Followed. This supersedes the
home's ordinary-result title list in decisions 1–2 and the automatic completion
read on opening in decision 4. The existing notification target routing, failure
rows, controls and backing-off reminder schedule remain in effect.

- Opening a completion summary does not imply reading the full result and cannot
  silently retire the followed reminder budget. Only **Mark as read** submits the
  displayed source/pairing/session/completion. Opening a wait still sends its
  independent seen receipt; this is neither approval nor an answer.
- Explicit completion intent may wait offline and survive restart. Legacy pending
  records were generated by page appearance and cannot be restored as explicit
  consent. Definitive transport receipts stop retries; authority snapshots decide
  the list and counts. New rounds and pairings do not inherit old intent.
- The headline states completed total and unread count separately. The home shows
  followed unread results; other unread completions get a phone-projected count
  and **View on your iPhone**, without a new title list. Missing count in an older
  relay is unknown. The existing bounded result payload is retained so notification
  targeting and existing failure detail do not lose their data.
- The detail labels actual Mac completion summaries separately from fallback task
  status. Both are partial reading aids; empty text points to the phone.

The cost is one deliberate tap to mark a summary read and taking out the phone to
identify ordinary unread results after the notification. No new notification
intensity, session observation-health projection or automatic iPhone navigation
is introduced. These are local implementation decisions, not evidence that
physical-device delivery or owner acceptance has passed.

## Amendment: the recap — what ended while you were not looking (2026-09-14)

The owner's 2026-09-13 direction (`.scratch/watch-recap-crown`, eight decision
tickets) extends *tell me why* to the stretch of time the owner was away: the
wrist answers "which rounds ended since I last read, and how", not only "who
needs me now". This is an extension of this ADR, not a new dashboard, and it
lands as an amendment rather than a new decision record.

- **Recap entry, Recap horizon, Recap** (terms in `CONTEXT.md`). The Mac's
  `RecapLedger` records every ended round — `completed` or `failed`, never one
  the user stopped — for seven days, and the snapshot carries `recap`: the
  entries after the **horizon** (the moment the user last confirmed a recap)
  and within 24 hours, newest first, at most twelve. The iPhone relays it as
  is; the Watch filters nothing and generates nothing. A round already read
  elsewhere stays in the recap with a read mark, so the recap still tells the
  whole story of the period.
- **The home's Recap row replaces the Results section and the "N unread outside
  Followed · View on your iPhone" line** of the 2026-09-13 amendment above: one
  row — "N since you last read · k failed · newest 12m ago" — that opens the
  recap. The attention order of decision 1 is unchanged (headline and card,
  *Also waiting*, then the recap, then *Followed* — now only running sessions —
  then quota and footer), and every row still opens. The bounded `results`
  payload stays on the wire for notification targeting; the wrist no longer
  renders it.
- **The recap is read with the Digital Crown**: `TabView(.verticalPage)` — an
  overview page (count, a static timeline, failures), one page per round, and
  an end page. No custom crown handling, no focus management, no playhead
  (ticket 05 of the effort). Viewing stays viewing (decision 4): opening,
  turning and leaving the recap send nothing.
- **Mark all is explicit confirmation in bulk.** The end page's one action
  reads each completed round the recap showed through the existing
  exact-round `/acknowledge`, then moves the Mac's horizon to the newest round
  it showed (`POST /recap-read`, forward only, idempotent), so the phone's and
  Mac's badges and the followed completion reminders (decision 5) stop
  together. The reads go first because a snapshot whose horizon has moved is
  what retires the queued request: a read that failed after the horizon would
  never be retried. A round the user had put back to unread counts as unread
  here. It is queued and persisted on the Watch (`WatchRecapQueue`, the
  same rules as the exact-round read: offline retry, a definitive receipt
  stops retries, only an authority snapshot whose horizon has reached the
  request changes what is shown), plays one local `.success` tap, and has no
  confirmation page. A recap that refills after being emptied opens on its
  overview, never on the end page.
- **Ordered by time, not by the queue.** ADR-0022 §5 orders the wrist's alerts
  and its `results` payload by the shared pending queue, and that stands. The
  recap is a different thing — a review of a stretch of time, not a queue of
  things to act on — so its pages run newest first by the moment each round
  ended, and the home's Recap row sits where the Results section did, after
  *Also waiting*, without changing the queue order of what is above it.
- **No new cue.** There is no scheduled "your recap is ready" notification, no
  Watch-side scheduler and no new notification category (ADR-0012 stands);
  each completion keeps its own mirrored cue. The recap's 24-hour window is
  its own rule, distinct from `SessionCurrency`'s 24 hours, which governs
  what a list shows and a count counts.

What a simulator cannot prove stays listed in tickets 11–13 of the effort:
detent feel and paging speed, the `.success` tap, Double Tap reaching Mark
all, and the mirrored notifications' behaviour, all need a paired device.

## Amendment: Mac recap reader and confirmation (2026-09-14)

Inbox and the Mac sidebar open one global Recap reader, directly from
`Snapshot.recap`. Each `RecapEntry.id` remains a separate round, including
several rounds of one Session. Selection shows only that round's recorded
points; Open current task explicitly navigates to live Session detail. Arrival
does not change selection; a removed selection is explained. Unavailable
capability, cached data and an empty authoritative recap have distinct copy.
Opening, selecting and scrolling do not acknowledge or move the horizon.

Confirm this recap is an explicit, source-bound operation over the displayed
batch: its completed unread identities use exact-round acknowledgement first;
once each is accepted or definitively skipped, its maximum endedAt advances
the horizon. A failed read leaves the horizon untouched. These are separate writes, never
review or acceptance. Failed rounds get no read write and remain Needs you.
A new round cannot join an existing operation. Recoverable partial failures
retain their original identities in the Mac model across navigation, even
if another device's horizon update empties the reader; retries do not expand the batch. The
same-process store's definitive stale/unavailable results are retained as skipped,
never claimed read, while failed writes remain retryable. The Mac
does not create a persistent offline queue or use the Watch pairing protocol.
Only authoritative snapshots change counts. A configured ledger persistence
failure must return failed without advancing the in-memory horizon.

Each entry retains the upstream ledger's last observed read mark after its
round stops being current; Mark Unread on the current round restores its unread
mark. This remains bounded recap storage, not a permanent reading archive or
an API for independently changing an old round's read state.

### 2026-09-14: Watch Recap removed after physical acceptance

The owner confirmed build 33 was running on the Watch, but Crown navigation
remained severely laggy. The owner then requested deletion rather than a
hidden feature. Build 34 removes the Watch Recap row, sheet, Crown pager,
demo launch entry, and Watch-side bulk-read submission and retry handling.
There is no enable switch. Phone and Mac Recap are unaffected. This supersedes
the Watch Recap presentation and Mark all decisions above; individual task
actions and their acknowledgement queue remain available. Removing the
feature does not mark any rounds as read.

## Amendment — task-specific notification suppression (2026-09-14)

Physical acceptance found a followed Codex completion suppressed as
`focusedTerminal` merely because Codex Desktop was frontmost. App-level
presence cannot identify the selected task and must not suppress sibling
task reminders. Only a positively identified, current task view may reduce
that task's cue; when native tab identity is unknown, retain its configured
notification delivery. The Mac currently identifies its own dashboard/glance
task view. Completion-summary delivery rechecks use the same exact view.
This does not change Presence-based approval routing or grant remote actions.

## Amendment — followed completion sound (2026-09-14)

Physical acceptance confirmed that a real followed task completion appeared
on the wrist without vibration, while a separate sound-bearing push did
vibrate. The shared delivery matrix had intentionally made all completions
silent, causing both APNs and iPhone local delivery to omit notification
sound. Followed completions now use bannerSound; normal completions remain
banner-only and muted completions remain dropped. This applies to completion
reminders too, with the existing backing-off schedule. Per-device sound
switches and Quiet mode still apply. The system controls wrist haptics; APNs
acceptance alone is not physical haptic proof.

## Amendment: task access after removing Watch Recap (2026-09-14)

Physical acceptance found a connected home showing a working count but no task row. The count was plain text, normal working sessions were absent from the task projection, and completed tasks were filtered out after the Recap entry was deleted. Keep Recap deleted. Home now lists unread current results through the existing exact-session detail, and all current working sessions through the same plain scrolling rows. These are current tasks, not historical rounds or Crown pagination. Followed remains the user's notification/complication choice; making a normal working task openable does not follow it or change its delivery policy. Opening does not acknowledge; Mark as read retains the existing exact source/session/completion operation.

The separate physical failure where opening a mirrored notification spins on the app icon remains unverified and is not claimed fixed by restoring task rows.

## Amendment — notification navigation waits for the main window (2026-09-14)

Physical acceptance reported that tapping the notification app icon flashed away without entering the task. The cause of that physical launch failure is not established by a unit test. A reproduced lifecycle defect in the existing router dispatched its target during store construction or while the main window was inactive. The router now retains the latest tapped session until both its handler and the active main window are available. The window refreshes relay state before releasing the target; delivery consumes it once. Notification scenes cannot grant this readiness. Routing still opens the existing task detail and does not mark a completion read, approve a request, or change attention. Physical notification launch remains an acceptance gate.

## Amendment — Live Activity launch on Watch (2026-09-14)

The owner photo showed the system Live Activity wrapper with “Open on iPhone”, not the Watch task detail. Build 37 lacked `WKSupportsLiveActivityLaunchAttributeTypes`. Apple documents that omission as the fallback to this wrapper: https://developer.apple.com/documentation/activitykit/launching-your-app-from-a-live-activity . Opt in on the Watch app with an empty array (all current activity types). The iPhone activity emits `vibebuddy://session?id=...`; the Watch previously accepted only its source-bound task/quota URLs. Route the shared session URL through the existing buffered session router, deriving source and pairing from relayed state before offering controls. Preserve complication URLs, and do not mark read on launch. This covers the Live Activity entry separately from APNs notification default actions; APNs acceptance never proves either navigation path.

Build 38 physical retest still showed the iPhone wrapper. Narrow the launch declaration to the actual `VibeBuddyActivityAttributes` name rather than an empty array; the latter has reported device failures despite the documented wildcard behavior (https://developer.apple.com/forums/thread/761052). Show the executing Watch bundle version at the bottom of quota/connection information so phone installation cannot substitute for Watch runtime verification. This is a configuration correction/probe; device launch remains unaccepted until observed.

## Amendment — resolve Live Activity continuation through the phone (2026-09-14)

The owner confirmed Watch build 39 and a Live Activity tap reaching Home. Exact-task navigation remains a separate physical gate. Accept `NSUserActivityTypeLiveActivity` as well as URLs: when supplied, its activity ID is resolved against the iPhone's active/stale ActivityKit instances. Return only the exact session projected for the same source and pairing epoch. Never substitute another current task.

This lookup is a typed, read-only WatchConnectivity request/reply, with a ten-second deadline and visible failure. It is not a durable command. New navigation, cancellation and source changes invalidate the attempt; late replies cannot redirect the wearer. Opening retains existing explicit read/approval semantics. The comparison with pinned Home Assistant, Loop and Communicator sources is recorded in `.scratch/watch-architecture-research/README.md`; it supports separate snapshot, interactive and durable-intent responsibilities, without introducing another transport dependency.

## Amendment — notification target across process replacement (2026-09-14)

Build 41 device traces show a default notification callback while the main window remained inactive, followed by a new store process before manual opening. An in-memory router cannot carry the target across that boundary. Persist one short-lived launch intent, bound to source and pairing and expiring after five minutes; consume only on main-window activation. Explicit navigation clears it. This narrowly amends the earlier transient-navigation rule: it is startup handoff storage, not a durable operation/retry queue, and cannot acknowledge or control a task. This fixes target loss; OS foreground activation after the default notification tap remains a separate physical gate.

## Amendment — refresh task content on opening (2026-09-14)

Build 43 physical notification navigation succeeded, but the task still displayed build 41 content until the owner opened the phone. Latest-value application context is a cache transport, not an on-demand freshness guarantee. Opening a Watch task now issues a typed, source/pairing-bound immediate request; iPhone obtains a fresh Mac snapshot through its existing authenticated client and normal snapshot application path, then returns the projected state. An overtaking stream snapshot is preferred to an older HTTP response. Pairing/generation changes invalidate the request.

The wrist bounds its wait to twelve seconds and consumes only the matching reply through its existing inbox. Leaving the detail or changing source invalidates the attempt. Failure keeps useful cached content visibly labeled with Retry. Refresh does not create read/approval intent; existing explicit pending actions retain their established semantics. Automatic background delivery and on-demand refresh remain separate responsibilities.

## Amendment — banner buttons act on the wrist (2026-09-22)

Decision 3's "Approve / Deny / Reply on a forwarded notification are answered by the iPhone, as Apple routes them" is superseded by ADR-0033. Apple routes *background* actions to the iPhone; every banner action is now a foreground action, so a button tapped on the wrist launches the Watch app, is mapped by `WatchNotificationResponseRoute` and sent through the card's own `WatchSessionActionRequest` path, with the card's sentences and a haptic for the outcome. Decision 4 is unchanged: the card still never says "approved".

## Amendment — roadmap M-07 / M-09 / M-10 scope (2026-09-23)

A survey of first-party and open-source products settles the three open Watch nodes. Neither Anthropic's Claude app nor OpenAI's Codex Remote ships a Watch app; both keep start, steer and approve on the phone and forward notifications to the wrist. Third-party Watch apps for coding agents (shobhit99/claude-watch, Handwave, watch-control) converge on remind → approve or answer, with dictation sent only to an existing session. None starts a new task from preset Mac / project / agent combinations.

- **M-07 narrowed.** Show the full question or approval object on the wrist and let a result excerpt expand. On-wrist read-aloud is not built.
- **M-09 deferred.** Answering a waiting session already covers dictation to an existing session. No evidence yet of demand for steering a running turn from the wrist.
- **M-10 wontfix.** Starting a new task stays on the iPhone. A wrong project picked by dictation is costly, and the node would need a confirmation page and another reliable send path.

