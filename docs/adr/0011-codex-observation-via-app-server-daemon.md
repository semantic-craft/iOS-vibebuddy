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
