# Codex integration contract and acceptance

Baseline checked on 2026-09-09: Codex CLI / managed installation / socket daemon /
Desktop bundled executable 0.153.4. Compare with the
[official changelog](https://learn.chatgpt.com/docs/changelog) when upgrading;
this date is an evidence baseline, not a permanent claim of latest support.

## Runtime ownership is separate from version

A daemon on `~/.codex/app-server-control/app-server-control.sock` exposes the
threads it owns. Desktop may run a separate stdio app-server. In the observed
0.153.4 Desktop setup, its task was not loaded in the socket daemon, and resuming
it there returned `already has an active writer`. Do not restart another writer,
remove locks, or treat a healthy/version-matched socket as Desktop connectivity.

Desktop lifecycle/tool hooks reached VibeBuddy in the controlled test, but an
on-request `require_escalated` command displayed a native approval while
VibeBuddy remained working without a pending card. No approval-wait event was
written to the rollout during that interval. These observations establish the
tested gap; they do not establish that all Desktop approvals or hooks behave
identically. A rollout tool call alone cannot identify an approval wait.

MAS scope remains subject to its existing product decision. Neither “Desktop
never runs hooks” nor “hooks guarantee Desktop approval coverage” is supported.
Actual sandboxed inbound delivery and device approval require their own proof.

## Version-specific protocol checks

[Generate schemas](https://learn.chatgpt.com/docs/app-server#message-schema) with
the installed binary. `tools/codex-integration/probe.py audit` checks literal
monitor method names, critical request fields, version drift and hook trust.
This is a bounded check, not complete generated-code validation.

- Steering requires an observed `expectedTurnId`; an unknown turn is not sent.
- Sandbox approval displays the requested filesystem/network profile and grants
  that profile for the current turn only. Its card cannot set persistent rules
  or a VibeBuddy session allow-list entry. HTTP and Mac handlers enforce this.
- Special filesystem scopes, glob scan depth and long permission details must
  remain visible before approval.
- MCP elicitation is read-only until its input contract is supported. Native
  resolution withdraws the corresponding card; no fabricated form response.
- App-server waits and their resolutions use the `appserver` lifecycle source.
  Session-level observations alone do not identify the source of a given card.
- Failed/empty trust queries and disconnect clear the prior trust verdict.

The maintained [Codex ACP adapter](https://github.com/agentclientprotocol/codex-acp)
regenerates types when upgrading its bundled Codex dependency. Borrow the
version/contract coupling and exact-decision approach, not an extra translation
layer: VibeBuddy's purpose is to observe existing tasks, not to own a new agent.
Development-branch fields absent from the installed schema are not assumed.

## Verification

See [probe instructions](../tools/codex-integration/README.md). Record these
separately: version/contract audit; route/regression checks; actual daemon-owned
thread; Desktop-origin task; installed app; physical phone; MAS sandbox.

The source probe records only selected-task metadata and declares a failed
subscription explicitly. It never treats unavailable app-server events as a
negative event observation. Keep evidence before changing a product capability
claim. Read-only probes do not grant hook trust or change Codex configuration.
