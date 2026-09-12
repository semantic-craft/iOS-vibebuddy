# ADR-0018: A Cursor cloud agent is observed and continued through Cursor's Cloud Agents API

- Status: accepted
- Date: 2026-09-12
- Supersedes / amends: amends ADR-0016 (Cursor observation and control), whose
  "Alternatives rejected" deferred this to its own decision and its own ticket.
  Sits beside ADR-0009 (daemon security) and ADR-0011 (Codex through the
  app-server daemon).

## Context

ADR-0016 left the Cloud Agents API out on purpose: it needs a `CURSOR_API_KEY`
separate from both the Cursor app's cookie and the `cursor-agent` CLI's own
login, "so it is its own decision and its own ticket". This is that decision.

**ADR-0016 says cloud agents "are already *visible*" because "they carry
`bc-`-prefixed ids and appear in the composer store like any other
conversation". That is not true on this Mac.** Cursor's
`globalStorage/state.vscdb` here holds 16 conversations, every one of them a
plain UUID with `agentLocation.type` either `local` or absent, and not one
`bc-`-prefixed row in `composerHeaders` or `cursorDiskKV` (checked 2026-09-12).
Whether that is because no cloud agent has ever been launched from this machine
or because the desktop app does not sync them at all, the conclusion is the same:
**the local database cannot be relied on to know that a cloud agent exists.**

That matters because everything else about a cloud agent points the same way. It
runs on Cursor's machines against a **GitHub repository**, not on this Mac
against a folder. No hook fires for it. No transcript is written for it. It has
no local branch checkout, no terminal and no window. All three of ADR-0016's
layers are silent — not merely quiet, but structurally inapplicable.

The API was re-read on 2026-09-12 against `cursor.com/docs/cloud-agent/api/*`,
and two things in ADR-0016's own description of it are now out of date:

1. **`POST /v0/agents/{id}/followup` is not the current shape.** v1 is the
   current surface (public beta; Cursor says it may change before GA) and v0 is
   legacy. v1 splits the work into a **durable agent plus one run per prompt**,
   so a follow-up is `POST /v1/agents/{id}/runs` with `{"prompt":{"text":…}}`.
2. **An agent takes a follow-up when it is *idle*, not while it is running.**
   Agent status is exactly `ACTIVE` / `IDLE` / `ARCHIVED`, `IDLE` is documented
   as "the last turn finished and follow-ups are accepted", and
   `POST …/runs` answers `409 agent_busy` when a run is already `CREATING` or
   `RUNNING`. Forum answers describing the opposite are about v0.

The agent id in the API is the same `bc-…` id the composer store already holds,
so the two views join on an identity vibebuddy keeps anyway.

## Decision

**A cloud agent is not a local conversation with a remote status. It is a
session with no local anchor, and the API is its only source — of its state and
of its existence.** This is the shape the codebase already has a place for:
ADR-0011's Codex Desktop threads, which run no hook, keep no terminal, and are
addressed by a URL rather than a window.

ADR-0016's layer order is unchanged and its rules still hold where they applied —
it simply has nothing to say about a conversation that never touches this Mac:

- **Hooks** remain the live, answerable source for conversations that run on
  this Mac. They never fire for a cloud agent, so nothing competes.
- **The agent transcript** remains the fallback tail for local conversations.
  None is written for a cloud agent.
- **The composer store** still never moves the three states, for either kind. It
  names the conversation, its project, its branch and its model, and it is what
  decides a cloud agent exists at all.
- **The Cloud Agents API** supplies `bc-` rows outright and moves their three
  states. `ACTIVE` is `working`; `IDLE` is `done`; `ARCHIVED` ends the session.

So the layering forks on *where the conversation runs*, rather than stacking a
fourth authority on top of every row. Two sources never describe one
conversation, which is why no authority window like ADR-0016's two-minute
transcript rule is needed here.

**The repository stands in for the project**, since there is no folder: `repos[]`
from the per-agent endpoint, fetched once per agent and kept, because it cannot
change. **The row is bounded** the way `cursorHistoryLimit` bounds the composer
store — archived agents excluded at the query, the list capped — for the same
reason: a dashboard is the work in hand, not an account archive.

**It is a tail, not an import — with one deliberate difference.** An agent
already `IDLE` when vibebuddy starts produces nothing, so launching the app never
rings a completion for a run that finished yesterday. An agent already `ACTIVE`
*is* reported, because unlike a transcript already on disk, a run that is live
right now is not history.

**The key lives in its own Keychain slot.** `cursorCloudAPIKey`, beside
`cursorSessionCookie` and `cursorSessionCookie.imported` rather than inside
them: three Cursor credentials exist and none substitutes for another. Settings
writes it once and never reads it back — "a key is saved" is answered by a
metadata-only Keychain lookup, which cannot raise an authorization prompt and
cannot decrypt anything. No error message, log line or snapshot carries the key
or any part of it, which is why the client reduces a failure to Cursor's status
and `code` and discards its `message`.

**A follow-up is refused when Cursor would refuse it, and the refusal is the
mirror image of the local one.** A local Cursor turn can take a supplement
*while* it runs (queued for its `stop` hook) but needs a terminal to reopen a
finished chat. A cloud agent is the other way round: a running one is refused up
front — one run at a time, per Cursor — and a finished one is continued directly
by starting its next run. The refusal is worded from the live snapshot, and the
`409 agent_busy` that beats the check answers "try again once it finishes", not
a generic failure: nothing was queued, and Cursor has no waiting room for a
follow-up, so implying one would be a lie.

**Availability is read off the `.cloud` observation, not off the key.** The
phone cannot see the Mac's Keychain. A `.cloud` evidence entry appears only when
the Mac actually reached the API, so its absence covers a missing key, a rejected
key and an unreachable service in one honest sentence — and the local wording,
which sends the person to the Cursor hook installer, is never shown for an agent
that does not run on this Mac.

## Alternatives rejected

- **Using the API as a control path only**, leaving the rows as stored history.
  It would keep a row that says "finished" next to a Send button that starts a
  run, which is precisely the kind of mismatch ADR-0016 exists to prevent.
- **Reporting only on cloud agents the local composer store already lists.** This
  was the first decision taken here, on ADR-0016's word that such rows exist. The
  database says otherwise, and the rule would have made the whole feature render
  nothing. Anchoring a session that has no local folder, branch or transcript to a
  local database row was the wrong model regardless of what the query returned.
- **The SSE run stream** (`…/runs/{runId}/stream`). It is the better fit for
  live tool activity and is the only real-time option Cursor offers today
  (webhooks exist on v0 only and are "coming soon" for v1). It also needs a
  long-lived connection and `Last-Event-ID` resume, and polling already answers
  the question the three buckets ask. Left for when tool-level activity is wanted.
- **Leaving stop refused.** ADR-0016 says "Stop is refused, not attempted —
  Cursor exposes no interrupt". That is true of a local chat and **false of a
  cloud run**, which `POST /v1/agents/{id}/runs/{runId}/cancel` ends. Refusing
  would have been inventing a limitation Cursor does not have, so this ADR
  amends that sentence: stop is offered for a live cloud run and refused
  everywhere else it was refused before. Cursor's `409 run_not_cancellable`
  answers `notSent` ("this run has already finished"), not a failure, and a
  cancel is never retried — the rule ADR-0011 set for the Codex interrupt.
- **`POST /v1/agents` to start new cloud work.** Dispatch needs a repository and
  a starting ref, which is a separate surface from anything vibebuddy shows now.

**The jump opens the agent's own page.** There is no window to raise and no
terminal to focus, so `agent.url` is the only honest target — the Codex Desktop
answer to the same problem. The URL arrives from a network response, so it is
checked against a closed allowlist (`https`, a `cursor.com` host, no userinfo)
rather than escaped, on `CodexDesktopJumper`'s principle: nothing that is not
recognisably a Cursor agent page is handed to a browser.

**The runs list is the conversation.** v0 had `GET /v0/agents/{id}/conversation`;
v1 replaced it with the agent/run split and offers no equivalent. One run is one
turn, so `/recent-output` for a cloud agent reads the runs list and shows each
terminal run's `result`, oldest first. A run still going has no result yet and
contributes no line rather than a blank one.

## Consequences

- A cloud agent appears whether or not this Mac's Cursor has ever heard of it,
  with the repository it works on, the state it is actually in, its final text
  when a run ends, a jump to its page, a follow-up when it is idle, and a stop
  while it runs. A completion cue rings for a cloud run that finishes while
  vibebuddy is watching.
- Without an API key nothing changes and nothing is attempted: cloud agents stay
  stored-history rows, exactly as they are today.
- The API is in public beta. A renamed field or a new `status` value degrades
  one layer: an unrecognized status drops that agent from the pass rather than
  guessing a state, a failed poll ends nothing, and the composer store's row
  survives underneath either way.
- Two Cursor credentials now exist in vibebuddy's Keychain, and a person who
  configures only one gets exactly the capability that one buys — quota from the
  cookie, cloud agents from the key.
- Polling costs one list call per interval (20s), one agent call the first time
  an agent is seen, and one run call when an agent has just finished. Cursor
  documents no rate limit on `/v1/agents`; if one appears, the interval is the
  single knob.
- Rows now come from an account rather than from this machine, so a second Mac
  running vibebuddy against the same Cursor account will show the same cloud
  agents. That is correct — the work is genuinely the same work — but it is a
  new property, and the completion cue fires on whichever Mac is watching.
