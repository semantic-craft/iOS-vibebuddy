# Codex is observed through the shared app-server daemon

**Status:** Accepted (2026-09-05) — implements `.scratch/codex-official-surfaces/issues/01`.

## Context

Codex has one process every client shares: the local app-server daemon
(`codex app-server --listen unix://`), started by Codex Desktop or the CLI and
listening on `~/.codex/app-server-control/app-server-control.sock` — a unix
socket owned by the user (0600), speaking JSON-RPC 2.0 over a plain WebSocket
handshake, with no further authentication. Desktop, the CLI TUI, `codex agents`,
`codex queue` and the phone's Remote Control all attach to it; it supports many
clients at once, each with its own thread subscriptions.

Until now vibebuddy read Codex two ways: hooks for the CLI, and a tailer over
`~/.codex/sessions/**/rollout-*.jsonl` for Desktop, which does not reliably run
hooks (openai/codex #21639). The rollout only shows *that* a thread waits, never
the request itself; Desktop liveness was inferred from writer-lock files and
process probes; quota needed a spawned `codex app-server --stdio` per refresh.

A read-only probe on 2026-09-05 confirmed the daemon lists Desktop threads
(`thread/list`, with name, cwd, git branch, status and rollout path) and answers
`account/rateLimits/read` at once.

## Decision

The daemon is the **primary Codex observation source** (`ObservationSource
.appserver`), and hooks + rollout become corroboration:

- `CodexAppServerMonitor` keeps one connection, calls `initialize`,
  `thread/list`, and `thread/resume` with `excludeTurns: true` to subscribe to
  every loaded thread, and reduces `thread/status/changed`, `turn/*`, `item/*`
  and `thread/tokenUsage/updated` into the existing `HookEvent`s. An `active`
  status whose flags say `waitingOnApproval` / `waitingOnUserInput` is the
  wait signal Desktop never gave us before.
- It is **read-mostly by construction**: no `turn/start`, `turn/steer`,
  `turn/interrupt`, config, fs, process or plugin method is ever called, and a
  server-initiated request (approval, user input) is never answered here — only
  counted, so ticket 03 can see whether the daemon routes them to a second
  subscriber. vibebuddy never starts the daemon.
- In `SessionStore`, while a thread has healthy app-server evidence younger than
  five minutes, a rollout or hook event for it may enrich (tokens, branch) and
  is recorded as evidence, but does not move the three-state progress; a hook
  `SessionEnd` still does. Older or absent daemon evidence hands control back.
- The monitor is a Settings toggle (default on). Off, or with no socket, the
  previous paths run unchanged; the Settings diagnostics show a third source row
  for Codex with the connection state.
- The connection declares `experimentalApi` only because
  `thread/resume.excludeTurns` — the subscribe-without-history call — is gated
  behind it (verified against the daemon on 2026-09-05); no other experimental
  method is used.
- The protocol is experimental; the reducer's fixtures are pinned to the schema
  `codex app-server generate-json-schema` emits for the verified CLI version. An
  unknown method or a JSON-RPC error marks the source `unknownVersion` and the
  monitor falls back without taking the old paths down.

## Security

Any process running as the same user can open this socket and, unlike
vibebuddy, drive threads. That is the same residual risk ADR-0009 accepted for
the token file. vibebuddy does not enlarge the exposure: it never proxies or
re-exposes the protocol, never enables `--listen ws://` (whose auth is not
enforced on loopback), and binds nothing new.

## Consequences

- Desktop threads get true status, cwd, branch and wait kind without hooks or
  writer-lock heuristics; the "Abandoned" inference only applies once the daemon
  is gone.
- `ObservationSource` gains a raw value (`appserver`) on the Mac→phone wire, so
  a phone build predating this ADR must be updated alongside the Mac.
- Ticket 02 replaces the spawned usage adapter with the same connection;
  ticket 03 depends on the routing fact this monitor records.

## Amendment (2026-09-05): approvals and questions are answered on this connection

A live probe showed the daemon delivers `item/commandExecution/requestApproval`
to every connection subscribed to the thread, accepts the first response and
drops the rest silently. So the monitor now answers those requests, and
`item/fileChange/requestApproval` and `item/tool/requestUserInput`, from the
phone card: `accept` / `acceptForSession` / `decline`, or the per-question
answers. Desktop's own dialog stays open; whichever side answers first wins,
and `serverRequest/resolved` withdraws the other card without a second
notification. The vibebuddy allow store and "allow this session" answer at
once, with no card (ADR-0010). While the daemon reports a Codex session, the
CLI's PermissionRequest hook gate returns no opinion for it, so one request
never raises two cards. "Read-mostly" therefore now means: no turn is ever
started, steered or interrupted from here; requests the agent itself opened
are the only writes.

## Amendment (2026-09-05): new threads are started on this connection

Implements `.scratch/codex-official-surfaces/issues/05`. `POST /dispatch` with
`agent = codex` asks the monitor to start a thread: `thread/start {cwd}` with
no model, approval policy or sandbox override (the daemon applies the user's
own defaults), the new thread is seeded into the reducer and subscribed at
once, `thread/name/set` when a name was given, then `turn/start` with the
prompt. The thread therefore appears in Codex Desktop, `codex agents` and
vibebuddy's buckets the same way a Desktop-started one does, and its approvals
and questions follow the first amendment. The route only accepts a `cwd` the
daemon has already seen a session run in (`Snapshot.recentDirectories`), which
is the whole of the "cwd whitelist"; vibebuddy never creates directories or
starts a thread outside them. Without a connected daemon the route answers 503.

## Amendment (2026-09-08): a running turn is interrupted on this connection

Implements `.scratch/watch-wrist-resolve/issues/01`. The wrist needs to *end*
things, not only watch them, so `SessionActionIntent` gains **stop** and
`CodexAppServerMonitor.interrupt(threadID:)` calls `turn/interrupt` with
`threadId` and the turn id — which the method **requires**, so the reducer's
`activeTurnID` (learned from `turn/started`) is what makes a stop possible at
all. A thread this connection attached to mid-turn has no known turn id and
cannot be stopped from here; that is reported, not worked around.

Scope of the opening, deliberately narrow:

- One call per stop. A `turn/interrupt` that throws or returns an error is the
  end of it: no retry, no `thread/resume` first, and never another method in
  its place. `turn/steer` and `turn/start` are not fallbacks for a stop, just
  as `turn/start` is not a fallback for a steer.
- The daemon decides against the live snapshot before it calls anything. Stop
  requires an `expectedStatusSince` matching the session's own — the moment it
  entered `working`. A session that is no longer `working`, or whose
  `statusSince` moved, is refused (409) and nothing is called. `requestId`
  de-duplication is the existing `ActionRequestLog`, so a double tap
  interrupts once.

  `statusSince` is the session's clock, not the turn's, so this is a strong
  guard and not a proof. Two turns share one `statusSince` whenever the daemon
  misses the boundary between them — a reconnect resets the app-server
  reducer, and the re-seeded `active` status carries no turn id, so the
  session never passes through `done`. A stop held from before such a gap
  would match and end the turn after it. Binding a stop to the turn id itself
  would close this, and would mean putting the turn id on the wire for the
  client to echo back; that is not done here.
- Codex only. Claude Code has no official remote interrupt contract and a tmux
  Escape is not one, so its reason reads "Stop this on your Mac"; Grok, Grok
  Bot and Cursor keep their existing unsupported wording. This is the user's
  2026-09-08 decision, not a limitation of this connection.
- Stop changes no attention and raises no cue. The next snapshot — the
  daemon's own `turn/completed` (`status: "interrupted"`) — is the only thing
  that says the turn ended, which is why an accepted stop is reported as
  *sent*, never as *stopped*.

  Making that true took one more fact. Codex reports a stop the user asked for
  exactly as it reports any interruption, and `FailureHeuristic.markers`
  contains "interrupted", so the ending would land as `failed`: red instead of
  done, no completion, and `agentStuck` — the error cue — for something that
  went exactly as asked. Only the Mac that sent `turn/interrupt` knows the
  difference, so it is the Mac that records it. The monitor claims the thread
  *before* the call goes out (the ending can arrive while the request is still
  in flight), the ending it claims is marked `userStopped` on its way to the
  store, and `AgentSession.userStopped` carries that to the phone and the
  Watch, where `SoundPolicy` stays silent for it. The claim is dropped after
  sixty seconds, so a stop whose ending never came cannot mislabel the next
  one, and an interruption this Mac did not ask for still reads as a failure —
  vibebuddy only vouches for the stops it sent itself.

"Read-mostly" now means: the writes are the ones a person asked for — a reply
to a request the agent itself raised, a dispatched thread, a steer, and a stop.
