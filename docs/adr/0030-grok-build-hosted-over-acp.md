# ADR-0030: Host VibeBuddy-started Grok Build sessions over ACP

- Status: accepted
- Date: 2026-09-21
- Related: [ADR-0016](0016-cursor-observation-and-control.md), [ADR-0010](0010-always-allow-in-vibebuddy-store.md)
- Delivery status: the decision was merged separately in PR #232. PR #233 implements it for Mac 1.3.25; it was not included in Mac 1.3.24.

## Context

Grok Build 1.0.40 documents that allowing a PreToolUse hook does not answer
Grok's own permission prompt. Hooks therefore cannot provide full remote
control of an ordinary terminal session. Its bundled agent-mode guide describes
an ACP process that a client can start and own.

The [assessment](../research/agent-integration-assessment-2026-09-21.md)
separates official protocol documentation, recorded Grok probes, the saved
prototype, and remaining acceptance work. The saved prototype passed package tests but lacked Mac dispatch and voice
wiring. PR #233 closes those gaps and the cancellation and result-mapping
regressions found during acceptance. See the assessment for evidence and limits.

## Decision

1. Use one `grok agent [-m MODEL] --no-leader stdio` process per session
   explicitly started by VibeBuddy. Do not attach to an existing terminal or
   leader session. Do not silently fall back to a terminal launch when the
   hosted launch fails.
2. Carry permission requests, questions, prompts and cancellation over that
   session's ACP connection. Keep native deny rules and VibeBuddy's existing
   allow policies. Do not change the user's Grok permission mode.
3. Continue an idle hosted session with `session/prompt`. Queue a supplement
   to a running turn for the next prompt; do not promise mid-turn steering.
   Record a user stop only when this client sent cancellation. A denied
   permission is not evidence of a user-issued stop or a successful result.
4. Use the native session ID to reconcile hooks and ACP. While ACP owns the
   session, hooks may enrich it but must not produce duplicate approval cards
   or completions. Ordinary terminal sessions retain their existing hook path.
5. Advertise Grok dispatch only when the executable and saved-login prerequisite
   are available, and report handshake or authentication failures explicitly.
   Mac, HTTP and voice entry points must reach the same host.
6. Defer leader attachment and restart recovery. A stopped host must lose its
   live control claim; persisted metadata is not a working connection. Do not
   describe a surviving process as remotely controllable after host loss.

## Alternatives

Approving through PreToolUse cannot answer the ordinary Grok permission prompt.
A shared leader may offer a different control model, but permission fan-out and
ownership need separate verification. Neither is a fallback in this design.

The transport may reuse the existing ACP client. Grok-specific extension shapes
remain in the Grok adapter; a change must preserve Cursor's existing behavior.

## Implementation gate

Keep implementation in a separate PR. Before merging it, fix Mac New task and
voice routing; check permission/question cancellation races and host cleanup;
run both package test suites on current main; exercise the affected app and
HTTP paths with a real Grok process in an isolated environment. Historical
probes and scripted protocol tests do not satisfy app acceptance.

Use a separate E2E bundle ID, storage root, token and non-production port.
The implementation must provide a deliberate isolated Grok opt-in before
claiming Mac end-to-end acceptance. No installed-app replacement is required
by this decision.

README, CONTEXT and setup instructions must describe ACP as supported only
when the corresponding implementation has passed these gates and merged.

## Amendment 1 (2026-09-24): restart recovery, and what a leader offers

**Measured** on grok 1.0.41 in disposable homes (evidence in
[ticket 02](../planning/backlog/agent-integration-2026-09/issues/02-grok-leader-fanout-and-recovery.md)
Comments):

- `session/load` in a fresh `grok agent --no-leader stdio` continues a session
  another process created: Grok replays the history as `session/update`
  messages, then the next `session/prompt` answers from it. An id Grok has no
  directory for fails with `-32603 "Path not found."`. `grok --resume=<id>`
  reopens the same session in the TUI.
- Leader mode (`[cli] use_leader = true`; the TUI spawns `grok agent leader`
  with its socket in the Grok home): a second client connected with `grok agent
  --leader stdio` lists the TUI's session (`session/list` and
  `_x.ai/sessions/list`, plus `_x.ai/sessions/changed` pushes), attaches with
  `session/load`, and receives the TUI's own `session/request_permission` at
  the same moment the TUI shows its prompt. Its `allow-once` answer closes the
  TUI prompt and the tool runs; an answer in the TUI reaches the other client as
  `_x.ai/session_notification: interaction_resolved`. Killing the TUI leaves
  the turn running in the leader: hooks keep firing and no `SessionEnd` comes.
- A file hook's `timeout` is honoured past the SDK's 600 s cap: a `PreToolUse`
  gate with `timeout: 1800` was cut at 1 800 s ("timed out after 1800000ms",
  fail-open), and one that answered `deny` after 758 s blocked the tool.

**Decision.**

1. Decision 6 is lifted for restart recovery. Every session this host starts
   leaves private metadata (`GrokACPRecovery`: id, directory, model, created /
   updated; 0600, 30 days, at most 100 records) and holds the same process
   lease Cursor's recovery uses. After a restart the row is registered as
   reloadable — not a live channel — and Continue starts a new `grok agent
   --no-leader stdio` and `session/load`s it before sending. A failed load
   keeps a retryable reason on the row and points at the terminal: opening the
   row on the Mac (the jump action, also from the phone) runs `grok
   --resume=<id>` in the preferred terminal, and the terminal owns the session
   from then on (its record is removed). The lease refuses both while the old
   process still runs.
2. Leader attachment is viable and is the only channel found that approves a
   terminal Grok session remotely. It is not built here: `use_leader` is off
   by default, attaching makes vibebuddy a second approver on the user's own
   session (first answer wins), and hosted sessions keep `--no-leader`
   (decision 1). A follow-up ticket may add an opt-in attach for users who run
   a leader.
3. A blocking `PreToolUse` gate could wait for the phone as long as its
   `timeout` (up to at least 30 min), but a hook `allow` still does not answer
   Grok's own prompt, so this only lengthens remote *deny*; the 30 s gate is
   unchanged.
4. While a leader answers in the Grok home, the session registry is not used to
   retire rows (a session outlives its terminal), see AI-03.
