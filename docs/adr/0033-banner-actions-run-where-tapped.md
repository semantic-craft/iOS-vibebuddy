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
5. **Reply from the wrist is bound to the current question.** A banner
   cannot name a question id, so `answer` binds to the session's question in
   the relayed state *now*, and only when the wrist may answer it at all
   (`isAnswerable`: a one-part question with the remote path available).
   Anything else opens the card, which says where the question can be
   answered.

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
- `WatchNavigationDiagnostics` records `notification.action-decide`,
  `notification.action-answer`, `banner.action-held`, `banner.action-sent` and
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
