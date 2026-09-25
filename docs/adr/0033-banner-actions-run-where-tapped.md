# ADR-0033: A banner button acts on the device it was tapped on

- Status: accepted
- Date: 2026-09-22
- Amends: ADR-0021 decision 3 ("Approve / Deny / Reply on a forwarded
  notification are answered by the iPhone, as Apple routes them") and the
  notification-categories PRD's actionable banners (ticket 05), which assumed a
  background action from the wrist would be carried out by the phone. Keeps
  ADR-0010 (the wrist encodes only `allow` / `deny`), ADR-0012 (one banner is
  one banner) and ADR-0021 decision 4 (viewing stays viewing; the card's
  sentences never say "approved").

## Context

On 2026-09-22 (Mac 1.3.28, iPhone Hermes on TestFlight 1.3.25 (55), Apple
Watch Series 10) hosted Cursor approvals were dispatched from the Mac and the
owner answered them from the wrist. Round R7 — open the card in the Watch app,
tap Approve — resolved on the Mac in seven seconds. Rounds R6 and R8 — tap
Approve on the notification banner — never produced a `POST /decision` on the
Mac, and the approvals stayed pending with nothing on the wrist, the phone or
the Mac saying that a tap had been made and lost.

Apple's rule, re-read from the DocC sources today, is the whole explanation:

> The system always handles foreground actions on the device where the user
> selected the action. […] The system always handles background actions on the
> device that was the notification's target. For example, if you send a
> notification to the user's iPhone and the system automatically forwards it
> to their Apple Watch, tapping the action runs it in the background on their
> iPhone.

Approve (`authenticationRequired`), Deny (`destructive`) and Reply were all
background actions. A tap on the wrist's banner therefore never reached
`WatchAppDelegate` at all — its `guard isDefault` was never the drop point —
and ran instead in `PushRegistration.handleNotificationResponse` on a phone in
a pocket: `BannerActionRunner` posted `/decision` over the network the locked
phone had at that moment, and on any failure returned `.openSession`, which
`UIApplication.open` ignores from the background. The tap had one observable
outcome when it worked and none when it did not. The Watch, which had drawn
the button, could not know either way; the phone, which did the work, had no
screen to say so; the Mac never heard of it.

The same shape applies to a button tapped on the *phone's* own lock-screen
banner: a background POST that fails leaves no trace.

## Decision

1. **Every banner action is a foreground action.** `LocalNotifier.
   registerCategories` adds `.foreground` to Approve, Deny and Reply. Apple
   then runs the action where it was tapped, on a device that is unlocked and
   whose app is on screen — so the outcome has a place to be shown.
2. **The Watch answers its own buttons through the card's path.**
   `WatchAppDelegate` maps a response onto `WatchNotificationResponseRoute`
   (Kit, pure, tested): the default tap and every action that cannot act
   `open` the session; Approve/Deny become `decide(sessionID, approvalID,
   choice)` bound to the approval id the notification carried; Reply becomes
   `answer(sessionID, text)`. `WatchStateStore.perform` opens the card first,
   then holds the action (`WatchBannerAction`, eight seconds of patience for a
   cold launch to activate WatchConnectivity) and sends it through the same
   `submit` / `submitAnswer` the card's buttons use — re-checked against the
   relayed state (`isDecidable`, `isAnswerable`, exact approval id) and the
   live link (`isLive`), and refused by the iPhone's `WatchSessionActionGate`
   again on arrival. Nothing about what the wrist may claim changes: `sending`,
   `awaitingResolution`, `failed`, `unknown`, `refused` are the card's own
   states and sentences.
3. **Never silent.** When a held action cannot be sent, the card the tap
   opened says why (`WatchBannerActionFallback`: no longer waiting, not
   decidable here, link down, busy, no state) above the buttons it still
   offers, and the wrist taps twice. When an action comes to rest the wrist
   taps once for taken and twice for anything else
   (`WatchHaptics.actionOutcome`), for banner- and card-initiated attempts
   alike. On the phone, a banner action now always lands on the session —
   after a success it shows the wait resolving, after a failure it is where
   the retry is.
4. **The Watch registers the same categories.** `WatchAppDelegate.categories`
   mirrors the phone's identifiers and options, so an independent watchOS
   delivery draws the same buttons with the same meaning. The mirrored copy of
   a phone notification draws the phone's; both agree.
5. **Reply from the wrist is bound to the question its banner named.** A
   banner names the permission it is about — `approvalId` rides in its
   `userInfo` — and, since #248, the question too (`questionId`, from the Mac's
   APNs payload and the iPhone's local notifier alike). The Watch reads it into
   the route and `WatchBannerAction` is bound the moment it is held, before
   any state arrives (amended 2026-09-23, WR-07). A cue from an older sender
   carries no `questionId` and is bound at the first sight of one instead: the
   first answerable question a *relayed* state holds for that session
   (`WatchBannerAction.bindsAnswer`). Either way the binding does not move. A held reply that followed the session
   would have answered whatever was being asked by the time it travelled — the
   agent answers "Delete the database?" and asks "Ship the release?", the
   lookup matches the new question, the iPhone's gate accepts it because that
   id is the live one, and the "no" meant for the first is recorded against the
   second. The card's own dictation pins `pendingId` when the words are made
   (`WatchAnswerDraft`); this is the banner's version of that promise, and it
   is why the wrist may send one at all.

   It is sent only when the wrist may answer with one string —
   `WatchAlert.isAnswerableInOneString`, the rule `WatchQuickAnswers.resolve`
   already applies on the card. A prompt the wrist walks question by question
   is `isAnswerable` and has a `pendingId`, so one dictated line used to pass
   here and be refused by the iPhone's `isSinglePart` gate on arrival, losing
   the dictation. Anything else opens the card, which says where the question
   can be answered.

   The sentence a refused reply leaves carries its question with it
   (`bannerActionFallbackPendingID`), so the question that *replaced* it — the
   very thing the sentence is explaining — does not take it back down.

   Where the words may go is one pure decision,
   `WatchBannerAction.replyStanding`: the bound question → send (if one string
   finishes it); a *different* question on the session → held like an
   absent request (nothing can be sent meanwhile except to the bound id) and
   refused as `.noLongerWaiting` once a newer revision still shows it or
   patience runs out; a question with no id on the wrist (part of it must be
   typed, and it may be the bound one) → `.notDecidableHere`; nothing → gone
   only when a newer revision proves it. A refused reply's words stay on the
   card (`WatchUnsentReply`, "Not sent: …") until the card closes, a new
   banner reply replaces them, or a *later* answer for that session reaches
   the iPhone or the Mac (`isSuperseded` counts only a change, since the
   action state is re-published on every install). A banner reply that did
   leave the wrist and comes back `refused` or `failed` said nothing to the
   agent, so its words are put back the same way (`restored`; not for
   `unknown`, which the Mac may have); where the card can answer in one string it offers
   **Use my reply**, which opens the ordinary confirmation page on the
   question being asked *now* — so re-pointing the words is the wearer's
   choice, never the wrist's.

   **Residual — closed for current senders (2026-09-23, WR-07).** The gap this
   paragraph used to describe — between the tap and the first relayed state
   the wrist has only its disk cache, whose ids `WatchStoredState` strips, so
   a question that changed inside it was inherited silently — no longer exists
   when the notification carries `questionId`: nothing relayed can move a
   binding made at the hold. What remains:

   - *Older senders.* A notification without `questionId` (an iPhone or Mac
     build before #248) still binds at first relayed sight, with the gap
     below. Diagnostics tell the two apart:
     `notification.action-answer` vs `notification.action-answer-unbound`.
   - *A lagging first state.* A live relayed state older than the
     notification can still show the previous question. The reply is held,
     not refused, until a newer revision decides it; if none arrives within
     the patience it is refused (`.noLongerWaiting`) — safe, never
     misdirected — and the sentence comes down once the newer state shows the
     bound question, leaving the words and **Use my reply** on the card. The
     cost of holding: a reply whose question really did change waits up to
     the patience (8 s) before the card says so.
   - *Id-less prompts.* The wrist cannot tell whether a prompt it holds no id
     for is the bound question; it says "decide it on your iPhone or Mac",
     which is true either way.

   For older senders, the binding is taken from the first *relayed* state, not
   the first state that passes the evidence guard. That distinction is the whole
   mitigation. `isLive` requires the phone to be reachable, and an unreachable
   stretch is exactly when a hold waits — so binding behind that guard let
   snapshots arrive, none of them able to bind, until the phone returned and
   the first settle took whatever was being asked *by then* as first sight.
   That moved the window rather than closing it, and stretched it to the full
   patience. Real ids do not depend on the phone being reachable this instant;
   only sending does.

   Whichever way the binding was made, the wrist refuses rather than guesses
   whenever it and the live question disagree.

## Alternatives rejected

- **Keep background actions and fix the phone's failure path.** Posting a
  local "couldn't send your approval" notification from the background would
  reach the wrist, but the tap would still run on a device nobody is looking
  at, on whatever network a locked phone has, and the wrist would learn about
  it only as a second buzz. The device with the screen should do the work.
- **Strip the buttons from the wrist and keep them on the phone.** Not
  expressible: a mirrored notification draws the category the phone
  registered, and one category cannot have background actions on the phone
  and none on the wrist. Removing them from the phone too would trade a silent
  failure for a slower success.
- **Handle the foreground action on the Watch without opening the card.**
  The card is the only place the wrist may show `sending` and its endings
  (ADR-0021 decision 4), and a foreground action opens the app regardless.

## Consequences

- On the phone, Approve/Deny from a lock-screen banner now opens the app on
  the session. Approve already required unlocking (`authenticationRequired`);
  Deny and Reply now do too, as a foreground launch asks for it.
- A tap on the Watch banner while the phone is out of range is not lost: the
  card opens with "can't reach your iPhone" and its buttons come back when the
  link does.
- ADR-0021 decision 3's sentence about Apple's routing is superseded by this
  record; the Watch is now the device that answers its own banner buttons.
- `banner.action-sent` is recorded only once an attempt has actually started.
  Both send paths re-run the checks the settle just made, so a refusal there
  should be unreachable; if one ever is not, it leaves a sentence rather than a
  diagnostic that says a vanished tap was sent.
- `WatchNavigationDiagnostics` records `notification.action-decide`,
  `notification.action-answer` (or `notification.action-answer-unbound` for a
  cue with no `questionId`; since WR-09 a Reply with no words records
  `notification.action-reply-card.no-text-response` or `.empty-text`), `banner.action-held`, `banner.action-sent` and
  `banner.action-fallback.<reason>`, so the next device round can prove which
  path a tap took without reading its content.
- What a simulator cannot prove stays listed for a paired device: that
  watchOS delivers a foreground action on a mirrored notification to the Watch
  app (Apple's stated rule), and the eight-second patience against a real cold
  launch.

## Note — the R4/R5 sessions that "finished" (2026-09-22)

The hosted Cursor sessions of rounds R4 (`2bfcc3d8`) and R5 (`43d65466`) were
still pending at 02:23 with their `cursor-agent` processes alive, and at
03:51 read `done` with no completion ledger and no marker file. This was not
an ACP expiry. The Mac app relaunched at 03:45:41 to install 1.3.29; its
hosted `cursor-agent` children died with it; on relaunch
`SessionStore.registerACPRecovery` re-created each session from its recovery
record as `status: .done`, `statusSince: updatedAt` (the dispatch time — which
is exactly what the snapshot showed) and "Managed Cursor session; reconnects
on continue", with no pending approval. The Watch learns of this the way it
learns of every resolution: the alert leaves the relayed state, the card's
buttons go with it, a held or in-flight attempt is reconciled away, and the
detail reads "not in the current Watch list". No separate expiry signal is
needed; what would help is a recovery row that says *why* the wait vanished
("your Mac restarted"), which is a Mac-side change outside this record.

## Amendment — what may end a hold (2026-09-22, review round 1)

Holding the tap was right; the first implementation gave the hold up on
evidence that was not evidence, and in two places let it vanish without saying
so. Three rules now govern it.

**Only a newer relay revision says the request is gone.** The first version
compared wall clocks: a payload installed after the tap meant the approval was
never coming. But the iPhone re-sends the context it has already sent —
`WatchStateInbox.accept` takes an equal `relayRevision` back when source, epoch
and `observedAt` all match, which is exactly what WatchConnectivity activation
does moments after a cold launch. So the R6/R8 tap, whose whole premise is that
the approval is *newer* than anything the wrist holds, was abandoned within a
second of arriving, and the card then claimed "this is no longer waiting on
you" above a live Approve button. The rule is now a revision, not a clock:
`WatchBannerAction.baselineRevision` is the revision held when the tap arrived,
or the first one to arrive if the wrist had none, and only a strictly greater
revision that still lacks the request may end the hold. The patience expiring
still ends it, with its own reason.

**Only leaving a card withdraws the decision made about it.** "There is no card
right now" is not "the person left the card". `openSession` clears `taskLink`
and `quotaSelection` on the way to setting the other, and a hold still waiting
for the state that can place its session has no card either. Both read as a
departure, and both dropped the tap with no sentence, no haptic and no
diagnostic. The withdrawal now hangs off the one event that means it: a
`taskLink` that had a value changing to another value or to none.

**A hold that gives up always has somewhere to say so.** `.noState` is reached
precisely when no card exists, so `WatchNoDataView` renders the fallback
sentence too. Nothing ends a hold silently.

Two further rules from the same round: a banner's Reply is refused for a prompt
the wrist walks question by question (`WatchAlert.isAnswerableInOneString`,
shared with `WatchQuickAnswers.resolve`, because the iPhone's `isSinglePart`
gate would refuse the dictation and lose it); and the phone returns early on
`UNNotificationDismissActionIdentifier`, which neither category asks for today
but which would otherwise be opened as a session by the new `.ignored` path.

Deliberately not changed: the eight-second patience. A cold launch that hears
nothing from the phone in eight seconds has a link problem, and a decision that
waits longer is a decision about whatever is pending by then. It now ends with
a sentence on screen instead of silence, which was the real defect.

## Amendment — what counts as evidence (2026-09-22, review round 2)

Round 1 fixed *when* a newer revision may end a hold. Round 2 found that the
states being measured were often not evidence at all.

**Only a state that came over the link, from a connected relay, may say
anything about a request.** Two others reach the settle path and neither can:

- The cache on disk. `WatchStoredState` strips `approvalId`, `pendingId`,
  `questions`, `request` and `summary` from every alert it saves — a cached
  command is deliberately never actionable. So on a cold launch the disk copy
  cannot match a tapped approval (`approvalId` is nil), and a tapped question
  matches on `waitKind` but then fails `isAnswerable` because `pendingId` is
  nil. A decision read from it looked resolved; a reply looked unanswerable and
  was refused outright with "this request can only be decided on your iPhone or
  Mac". Both false, both about the redaction rather than the world.
- A payload taken while the relay is down. `WatchStateInbox.accept` preserves
  the previous content and adopts the incoming `relayRevision`, so the
  no-source publish the phone makes before its first snapshot advances the
  number without changing the alerts — last week's list wearing a fresh
  revision, which the round-1 rule then read as proof.

The settle path now waits for `hasRelayedState && isLive(state)` before it
places, refuses, or retires anything.

**Running out of patience is not proof the request ended.** `provesRequestGone`
no longer takes `expired`; the timeout is the caller's to name, and it names it
`.noState` ("waiting for an update from your iPhone") or `.linkDown`, never
"this is no longer waiting on you". The wrist says what it knows, and after
eight quiet seconds what it knows is that it never found out.

**A sentence comes down when the state contradicts it.** `giveUp` records what
the sentence was about, and a later state holding that approval or question
again clears it — "this is no longer waiting on you" above a live Approve
button is worse than silence. The sentence also now renders on the tab pages
when no card exists, not only on the card and the no-data screen, because the
gap between them is exactly the no-Mac publish that produces `.noState`.

### Round 3, continued — the baseline, and sentences that were not true

Three more from the same round, on top of the reply binding above.

**The baseline may only come from evidence.** Round 2 left `perform` seeding
`baselineRevision` from whatever was on screen at the tap, which on a cold
launch is the cache. A live snapshot is legitimately newer than the cache and
legitimately may not yet carry an approval in flight, so it read as proof and
ended the hold at once — not even at the timeout, and the later snapshot that
did carry the approval then cleared the sentence without sending. The mark is
now set by `noteInstalled`, past the evidence guard: the first evidence state
is the baseline and proves nothing.

**The wrist names the link that is actually down.** "Waiting for an update from
your iPhone" was shown when the update had arrived and it was the Mac that had
gone. `waitingReason(for:)` reads the connection, and `.macLinkDown` says so.

**Each sentence stays exactly as long as it is true.** They were all cleared
together as soon as the request came back, which took down "another action is
still on its way" while that action was still in flight, and left "can't reach
your iPhone" up after the phone returned. Clearing is now per reason and runs
on link changes as well as new states: `.busy` waits for the slot, `.linkDown`
and `.macLinkDown` for a live link, `.notDecidableHere` for the request to
become actionable, and `.noLongerWaiting` either clears or — when the request
is back but not for this wrist — becomes `.notDecidableHere` rather than
staying false. `.noState` is the exception: "it wasn't sent" is still true once
the update lands, so it leaves with the card.

The fallback inset on the root pages is attached only when there is a sentence;
an inset that is always present still asks for the system's default spacing,
and every page would pay for it to serve a sentence almost nobody sees.

## Amendment — a sentence that stops being true is usually replaced, not removed (2026-09-22, review round 5)

Round 3 gave each fallback reason its own clearing rule. Round 5 found all
three of the remaining defects in that code, and they share a shape: a reason
stopping being true almost never means there is nothing left to say. It means
something else is now the reason.

**The in-flight slot freeing is an event in itself.** `.busy` was judged only
when a new state arrived, and `install` ran the refresh *before*
`pendingAction.reconcile` — so the snapshot that retired the attempt was judged
against a slot that still held it, and "another action is still on its way"
survived the action. A `.failed` reply with no snapshot behind it stuck
forever. The refresh now runs from `pendingAction`'s own observer when
`isBusy` changes, and in `install` after the reconcile, never before.

**Either link can be the broken one.** `connection` is `.live` for a fresh
payload even while the phone is unreachable, and the link sentences cleared
only on a fully live chain. So when the phone came back and the Mac was still
down, "can't reach your iPhone" stayed on the card while the link block two
lines below said the iPhone could not reach the Mac — two contradictory
sentences on one screen. `.linkDown` and `.macLinkDown` now re-derive from
`waitingReason(for:)` and swap.

**A reply with no bound question is about nothing — usually.** `standing`
treated a nil `bannerActionFallbackPendingID` as matching every question on the
session, so a reply that gave up before any id could be bound had its sentence
taken down by the next unrelated question. And `.notDecidableHere` now becomes
`.noLongerWaiting` once its request leaves the snapshot, rather than describing
a card that no longer holds it.

Round 6 caught the over-correction. There are two ways to reach a missing
binding and they mean opposite things. `.notDecidableHere` is refused *before*
the binding is taken, and refused precisely when the question carries no id to
bind — a prompt some part of which must be typed. So the missing id is the
sentence's own subject, still on screen, and reading it as "the request left"
rewrote a true sentence into "this is no longer waiting on you" while the
wearer looked at the thing that was waiting, above a card still offering to
answer it on the Mac. A question alert with no id is therefore
`.presentButNotHere`; `.absent` is kept for a later question that has one,
which is the case the nil rule was written for.

`.busy` keeps the stricter reading: it is only reachable after the binding
succeeded, so a missing id there honestly means the question left. The two arms
look alike and must not be folded together.

### For the device acceptance

A banner already sitting in Notification Center keeps the category actions it
was delivered with. After installing a build with this change, an older pending
cue still routes its buttons to the phone and will look exactly as though
nothing was fixed. The run must use a freshly posted notification.

## Note — first device acceptance (2026-09-24)

Hermes on a development build of main 9137f92f, Apple Watch Series 10 on watchOS 27, phone locked (face up until 11:25, face down after), fresh notifications.

- **Deny from the wrist banner: passed.** `notification.action-decide` → `banner.action-held` → `banner.action-sent` (+1 ms). The Mac hook returned `deny` 5 s after the push.
- **Approve from the wrist banner: passed three times.** The Mac hook returned `allow` 9 s after the push on two fake waits. A hosted Cursor approval passed too.
- **Reply from the wrist banner: never reached the watch with text.** Three times, watchOS opened the app with no text (`notification.action-opens`), 5–10 s after the push. Decision 5's binding is proven in the simulator only. What the button should become is ticket watch-wrist-resolve 09.
- The eight-second patience was not tested against a cold launch that needed it: every held action went out within 2 s.

## Amendment — Reply on the wrist opens the card (2026-09-25, WR-09)

On watchOS 27 a mirrored `.foreground` `UNTextInputNotificationAction` opened the Watch app with no input sheet, and no text reached the delegate (three device taps; whether the response carried nil or an empty string was not distinguished). Both the iPhone and the Watch register the same category (decision 4), so the observation cannot say which registration drew the button. Apple documents text input actions on watchOS but says nothing about mirrored foreground ones. Home Assistant hit a related but different failure ([home-assistant/iOS#5778](https://github.com/home-assistant/iOS/pull/5778)): there the input sheet appeared but the delegate was never called, with actions set per notification; here the delegate is called but no sheet appears.

Decision: on the wrist, Reply *is* "open the answer card". The phone keeps drawing its text field (not re-verified in this round). `resolve` already maps a Reply without words to `.open`; the Watch now records that tap as `notification.action-reply-card.no-text-response` or `.empty-text`, so the next device round both proves the path and settles the nil-versus-empty question. Decision 5's binding stays in place for any watchOS that does deliver text.

Rejected: a background text action (it runs on the iPhone, where a failure in a locked phone is invisible from the wrist — the reason for decision 1); Home Assistant's fix, a text button drawn by the long-look controller with its own send path (it would save the tap into the card, but the long look has no live store or relay behind it, the send would need its own WCSession path and failure sentence, and Home Assistant reports no paired-device evidence either — too large for this ticket, and the card path already works on the device); per-question option buttons on the banner (options differ per notification, so the actions would have to be set per notification — re-registered categories or the long look's `notificationActions` — and the push payload would have to carry the options).
