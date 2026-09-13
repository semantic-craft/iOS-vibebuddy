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
