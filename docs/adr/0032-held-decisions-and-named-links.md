# ADR-0032: A decision the phone cannot deliver is held, named, and delivered once

- Status: accepted
- Date: 2026-09-22
- Amends: ADR-0012 (the phone's receipts now also stand *down* a held
  decision's notification: one banner per decision, replaced in place);
  ADR-0021 §"the wrist reports `sending / accepted / failed / unknown /
  refused`" gains `queued`. Keeps ADR-0010 (the wrist still cannot persist a
  rule) and the `WatchSessionAction` contract.

## Context

On 2026-09-22, between 01:50 and 02:55, the owner approved four hosted
Cursor permission prompts from the Apple Watch. The Mac (1.3.27 then 1.3.28)
advertised its Tailscale address `100.64.0.2`; the phone reaches that address
only while Surge or Tailscale runs on the phone, and Surge was stopped. The
APNs pushes arrived — the Mac's delivery ledger says `apns accepted` — the
mirrored card showed on the wrist, the owner tapped Approve, and nothing
reached the Mac: no `POST /decision`, no ledger entry. The approvals stayed
pending for over thirty minutes. Neither device said a word; the phone app's
only sentence was *Disconnected*.

Three things were wrong, and they were wrong on different surfaces.

1. **The phone had one word for four faults.** A refused token, a bad
   address, a Mac that is asleep and a phone with no road to the Mac all
   read *Disconnected — reconnecting…*. The fourth is the only one a tap on
   the phone fixes, and it was the one that happened.
2. **A mirrored notification's action is answered by the phone, in the
   background, with no way to report back.** Apple routes the Watch's
   Approve button to the app that posted the notification
   (`WatchNotificationScene`), and that app ran `BannerActionRunner` →
   `POST /decision` → connection refused → `UIApplication.open(...)`, which
   does nothing from the background. The Watch app's own card *does* report
   `failed` through `WatchSessionActionState`, but the card the owner tapped
   was the notification, not the app.
3. **A failed delivery was dropped rather than kept.** The Mac's
   `ActionRequestLog` already de-duplicates `/answer` on a `requestId`, and a
   resolved approval already refuses a second `/decision` on its id. What
   was missing was a place on the phone to keep the decision and a key to
   retry it under.

## Decision

1. **The phone names the missing link.** `ConnectionDiagnosis` (Kit)
   combines the pairing's endpoint, the transport failure and one fact read
   live from the phone's interfaces — whether any interface carries a
   `100.64.0.0/10` address (`PhoneNetwork.hasTailnetAddress`) — into a
   `ConnectionFailureReason`: `tailnetOff(host)`, `macUnreachable(host)`,
   `authentication`, `invalidAddress`, `dropped`. `DashboardStore.failure`
   publishes it beside `state`; the dashboard's empty state and *Device &
   connection* show its title, detail and, for `tailnetOff`, a one-tap
   *Turn on Surge or Tailscale* that opens whichever app is installed
   (`surge:///start`, `tailscale://`) and falls back to the remote-setup page.
2. **A decision the phone cannot deliver is held.** `SessionActionQueue`
   (Kit, a value) holds approvals and answers — never a stop, which is bound
   to a turn that will not be there later — one per target, a later decision
   on the same target replacing the earlier one. `PendingActionStore` (phone)
   keeps it on disk, prunes it after six hours, twelve attempts or a
   re-pairing, and runs one delivery pass whenever the phone reconnects, is
   woken by a push, or the person taps *Retry*. Each pass re-reads the Mac's
   snapshot and judges the held decision against the live request, as a fresh
   tap is judged.
3. **One key per decision, end to end.** The item's id is the tap's
   `attemptId` on the wrist, the `requestId` on every `/decision` and
   `/answer` it makes, and the Mac's `ActionRequestLog` key. `/decision` now
   accepts `requestId` and answers a replay as it answered the first time —
   200 for a decision it applied, 409 for one it refused — instead of
   refusing the phone's own retry as a conflict. Only a *held* decision is
   ever retried, and only under that key. A decision is held when nothing
   was sent — the stream is down, or the Mac's snapshot could not be read —
   never when the Mac answered: a refusal stays `failed` (tap again), a
   receipt lost after the Mac may have acted stays `unknown` (look, do not
   tap), exactly as before. That keeps the rule *ambiguous POSTs are never
   replayed*; the key is what makes the held path's own retries safe. On
   the banner path only a POST that never left (no route, no host, no
   network) is held; a timeout or reset is a lost receipt. A held decision
   whose request is gone by the time the phone can ask is reported *gone —
   nothing applied* only if the phone never posted it; after a posted
   attempt without a receipt it is reported *could not be confirmed*. On
   the Mac, a replay whose twin is still in flight answers 503, as `/answer`
   does, so the phone keeps it unconfirmed rather than reporting delivery.
   A decision whose earlier decision on the same target is being posted
   this instant is refused rather than queued behind it. One decision per
   target across surfaces: the phone's card shows a wrist- or banner-held
   decision as its own receipt (buttons off), and a fresh card decision on
   that target withdraws the held one first. A banner tap whose receipt was
   lost (timeout, reset, refusal) is neither held nor retried; it posts
   *could not be confirmed — check the task*, the wrist's `unknown` in a
   notification. A hold the queue refuses (full, or the target in flight)
   posts *was not delivered — decide again*, never *on hold*.
4. **Every surface says where the decision is.** The Watch's reply
   vocabulary gains `queued` with a `reason`; the card reads *Your iPhone is
   holding this — Surge or Tailscale is off on it. It will be sent when the
   Mac is reachable.* The relay carries `heldActions`, so the card keeps
   saying so after a relaunch and stops saying so when the phone gives up.
   The Watch may send while the phone reports the Mac disconnected — that is
   exactly when holding is useful — and still may not when the phone itself
   is out of reach. The notification path reports through a notification of
   its own, replaced in place under one identifier per target: *on hold* →
   *delivered to <Mac>* / *no longer needed* / *was not delivered*. The
   phone's Inbox lists held decisions with *Retry* and *Cancel*.
5. **A waiting cue's push wakes the phone.** The Mac adds `content-available`
   to approval and question pushes and the phone declares
   `remote-notification`; on the wake the phone probes the Mac's
   unauthenticated `/health`, delivers what it holds if it can, and if it
   cannot, posts one time-sensitive warning — *Surge or Tailscale is off on
   this iPhone … decisions you make from here will be held* — before the
   person taps Approve into the void. The warning is withdrawn on reconnect.

## Consequences

- A tap on the wrist or the lock screen is never silently lost again: it is
  either delivered, held and reported, or refused with a sentence.
- The Mac's `/decision` grows a request log entry per keyed decision; the
  log is bounded (64) as before.
- The phone gains a background mode. iOS grants the wake at its own
  discretion; a force-quit app is not woken, and then the notification path
  still holds and reports on the next launch.
- `WatchSessionActionOutcome.queued` and `WatchHeldAction` are optional on
  the wire: an older Watch treats a `queued` reply as a lost receipt
  (*Couldn't confirm that*), which is the honest fallback.
