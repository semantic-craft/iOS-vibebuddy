# One banner per cue: the phone reports what it posted, the Mac's push stands down

**Status:** Accepted (2026-09-06).

## Context

Two devices can tell the user the same thing about one session. The iPhone posts
a local notification from the live snapshot stream the moment a session enters
`needsResponse`; the Mac pushes the same cue over APNs so the phone hears it when
the app is not running. Both carry one identifier (`NotificationIdentity`:
`<sessionID>-needs_approval`), which is the push's `apns-collapse-id` and the
local request's identifier, on the assumption that iOS would keep one.

It does not. On Hermes (iPhone 17 Pro Max, iOS 26.6.1) a lock screen showed both
`acceptance-ticket-11c 需要权限` (local) and `acceptance-ticket-11c needs
approval` (push) for one request. `apns-collapse-id` collapses pushes with each
other; a local notification with the same identifier is a separate entry, and
Apple's `UNUserNotificationCenter.add` documentation says a request that reuses a
delivered identifier *replaces* it — which presents again. Either way the second
arrival is a second banner and a second sound, and a phone cannot intercept a
push before it is shown (no service extension can cancel one). So for exactly one
banner, exactly one channel may deliver, and which one must be decided by the
side that knows what the phone did: the phone.

The hard constraint from the ticket: no scenario may receive fewer alerts than
today, and nothing new may be unreliable. A duplicate is tolerable; a missed
`needs_approval` is not.

### Measured on the real device (2026-09-06, Hermes + `vibebuddyd` on this Mac)

Hooks were posted at known times to an isolated daemon on `:9877`; the delivery
log records the decision and its clock. `filtered … phonePosted` means the phone
sent a receipt and the push was dropped; `accepted` with a timestamp inside the
hook's own round trip means the daemon had no `/ws` subscriber and pushed at once.

| App state when the wait began | Phone posted locally | Push | Result |
|---|---|---|---|
| Foreground (5 runs, daemon and menu-bar app) | yes (`active`), receipt 70–450 ms after the hook | filtered | one banner (foreground presentation) |
| Backgrounded 0.3–0.5 s earlier (4 runs) | yes (`inactive`) | filtered | one banner |
| Backgrounded 5–8 s earlier, app not yet suspended (3 runs) | yes (`background`) | filtered | one banner |
| Backgrounded 2.6 s / 5.6 s / 10 s / 20 s / 40 s earlier, app suspended (5 runs) | no — no `/ws` subscriber left | accepted immediately | one banner (push) |
| Backgrounded 5 min earlier | no | accepted immediately | one banner (push) |
| Backgrounded 39 s earlier, app briefly reconnected on its own | declined: push for that wait already in Notification Center (`pushCovered`) | (already sent) | one banner |
| App brought forward after six waits had been pushed while it was suspended | declined all six (`pushCovered` ×6, within 150 ms of the reconnect) | (already sent) | one banner each, none added on resume |
| Mac without an APNs key (`apns: off`): foreground, 0.4 s in background, 30 s in background | yes, yes, nothing (app suspended) | none | unchanged from before this change |

Suspension is not on a fixed clock: at +2.6 s the socket was already gone in
one run, while in another the app was still posting at +5.4 s and +8 s. Both
outcomes are handled by construction — a receipt filters the push, no receipt
lets it through — which is the point of asking the phone instead of guessing.

Two facts fall out of this, both of which the candidate designs depended on:

1. **The daemon sees the phone's socket go away when iOS suspends the app,
   which happened anywhere between 2.6 s and more than 8 s after it left the
   foreground.** The "phone online but suspended" window that made candidate 1
   dangerous is short, but it is neither fixed nor empty: until suspension the
   app still posts, and a backgrounded app can *reconnect* later on its own
   (observed 39 s after backgrounding). That reconnect is the mechanism behind
   the ticket's "a few dozen seconds after backgrounding" duplicate: the stream
   catches up, `SoundPolicy` earns the cue for a wait the push already announced,
   and the phone posts it again.
2. **A remote notification is visible to the app as a delivered notification whose
   `request.identifier` is the collapse id**, with a `UNPushNotificationTrigger`.
   The phone can therefore tell, before posting, that a push already covered a
   wait — and did, in the 39 s case above.

## Decision

Two rules, one per direction, both failing toward "push":

1. **The Mac holds its push for a phone's receipt.** When the phone posts a cue
   it sends `POST /notified` (`NotifiedPayload`: device token, the cue's
   identifier, the wait's start as the Mac reported it, the app state). The
   pusher (`APNsPusher.send`, both the daemon's `setNeedsResponseHandler` path
   and the menu-bar app's `pushToPhones` path) asks `PhoneReceipts` for a
   receipt matching *that phone, that identifier, that wait* (±1 s). If the
   store has a `/ws` subscriber it waits up to 3 s for one; with no subscriber
   nobody can be about to report, so it decides at once. A receipt means the
   push is `filtered`; none means it is sent exactly as before, at most 3 s
   later. Matching on the wait's start means a receipt for one wait can never
   silence the push for the next wait of the same session (the phone debounces
   re-entries for 90 s and would stay silent for it).
2. **The phone leaves a waiting cue to a push that already delivered it.** Before
   posting `needsApproval` / `needsAnswer` / `longWaitNudge`, `PushCoverage`
   checks Notification Center for a delivered *remote* notification with the
   same identifier dated at or after the wait's start (5 s clock tolerance), or
   a tapped one whose `didReceive` just brought the app forward. If found, the
   cue is not posted and the Mac is told (`coveredByPush`, logged as
   `phone filtered pushCovered`). Completions are not covered: they are never
   withdrawn, so a stale one could not be told apart from a new one, and the
   phone never posts a completion in the foreground anyway.

Everything the phone reports and everything the Mac decides lands in the
notification delivery log (`phone scheduled phonePosted:<state>`,
`phone filtered pushCovered:<state>`, `apns filtered phonePosted:<state>`), so
"why did my phone show this once / twice" is answerable from Mac Settings.

## Why not the other candidates

- **Skip the push while the phone's socket is open (candidate 1 as written).**
  The socket is not the phone. Up to suspension (2.6 s to 8 s and more after
  backgrounding, varying run to run) the app still posted; a lingering or
  freshly reconnected socket behind a suspended app would have swallowed the
  only alert. A "silent for N seconds" heuristic cannot distinguish a quiet
  phone from a dead one. The receipt is the positive form of the same idea: the
  push stands down only when the phone has said it posted.
- **Withdraw the push before posting locally (candidate 2 as written).**
  Withdrawal removes an entry; it does not un-present a banner or un-play a
  sound, and it covers one order only. Inverted — do not post when the push is
  already there — it is rule 2 above, which handles the order the Mac cannot
  see (the phone catching up after the push).
- **No local notification in the background (candidate 3).** It makes the
  background alert depend on APNs alone. The phone cannot see whether the Mac
  has a pusher or whether a send will be accepted, and a Mac without an APNs
  key would lose every background alert. It also trades the local path's
  milliseconds for a push round trip. Rejected on the hard constraint.

## Consequences

- A push to a phone that is suspended while its socket lingers arrives up to
  3 s later than today. A phone with no socket (the common closed-app case) is
  pushed with no delay.
- The wire gains `POST /notified` (bearer token) and the Kit gains
  `NotifiedPayload`; the delivery log gains the `phone` channel and the
  `filtered` outcome (Q26). `SettingsView`'s help text still lists the four
  older outcomes; it was out of scope for this change.
- `VIBEBUDDY_HOST/PORT/TOKEN` in the iOS app's environment now win over the
  saved pairing for that launch (never saved), so a device build can be
  pointed at a second Mac instance from `devicectl` during acceptance without
  redeploying the Mac app other sessions are using.
- The Watch mirrors what the phone shows; one notification on the phone is one
  on the wrist. Nothing on the Watch changed.
