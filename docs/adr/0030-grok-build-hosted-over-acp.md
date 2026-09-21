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
