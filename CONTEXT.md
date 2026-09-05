# vibebuddy — Domain glossary (CONTEXT)

The shared vocabulary for vibebuddy. Use these terms verbatim in issues, ADRs,
code, and tests — don't drift to synonyms.

## Core

- **Session** (`AgentSession`) — one coding-agent run on the Mac (Claude Code or
  Codex), tracked over its lifetime. Carries project, branch, model, tokens,
  context-window usage, and a **state**.
- **The three states** — every session is in exactly one, by priority
  **`needsResponse` > `working` > `done`**:
  - **needsResponse** — blocked on the user (a permission prompt or a question).
  - **working** — actively running between prompt submit and stop.
  - **done** — finished and not waiting.
- **waitKind** — when `needsResponse`, *why*: **permission** (approve/deny a
  tool/command/edit) or **question** (free-text answer).
- **failed / stuck** — a real failure signal: the Mac hook flags `PostToolUse`
  tool errors (`HookEvent.toolError`, parsed from `is_error` in `tool_response`),
  the reducer sets `AgentSession.failed` on stop, and `isStuck` drives the pet's
  stuck mood + stuck sound. The summary-keyword `FailureHeuristic` is now only a
  fallback.

## Mac side

- **Hook** — a Claude Code/Codex CLI lifecycle event (Notification, Stop,
  PostToolUse, SessionStart…) that feeds session state into the daemon.
  Fail-open.
- **Codex rollout stream** — the append-only
  `~/.codex/sessions/**/rollout-*.jsonl` event stream. Codex Desktop does not
  execute user CLI hooks, so its task/tool/completion progress enters through
  this local tailer and converges with hook events in the same reducer.
- **Daemon** — the Mac menu-bar app's embedded HTTP + WebSocket server
  (`:9876`) that ingests hooks, runs the reducer, and broadcasts snapshots.
- **Glance** — the Mac floating status panel at the top of the screen (notch or
  pill); hover to expand.
- **Pairing** — linking a phone to a Mac over the LAN by scanning a QR that
  encodes `host:port` + a **bearer token**.

## Buddy / pet

- **Buddy / Pet** — the companion character (a code-drawn **pixel cat**, unified
  across iOS and macOS per ADR-0007's amendment) that reflects overall status
  and hosts the voice companion. Zero third-party art.
- **BuddyState** — the mood enum driving the pet's face and the sound pack:
  `approval`, `question`, `longWait`, `working`, `stuck`, `done`, `sleeping`.

## Voice

- **Voice companion** — tap the pet to hold a **realtime speech-to-speech**
  conversation; it knows the live sessions and can **approve / answer** for you.
- **VoiceProvider** — the realtime backend: `qwen`, `openai`, or `gemini`. Each
  has its own key, model, voice, and input sample rate. Qwen additionally takes
  an optional Bailian **workspace ID** (workspace-specific `maas.aliyuncs.com`
  endpoint) and a Beijing/Singapore region switch.
- **RealtimeVoiceProvider / RealtimeVoiceEvent** — the provider-agnostic Kit
  protocol + event stream (connected, userTranscript, assistantTranscript,
  audioDelta, speechStarted, responseDone, failed, closed) that the audio + UI
  layers consume.
- **Conversation language** — the language the voice companion speaks (English /
  中文); independent of the **UI language** (English).
- **Approval / Answer** — the two remote actions on a session: approve/deny a
  pending permission, or inject a text answer.

## Observability (2026-09)

- **ObservationSource / ObservationHealth** — which signal currently backs a
  session (`hook`, `rollout`, `transcript`, `recovery`) plus its last-seen time
  and a health verdict (healthy / degraded / unsupported / eventsMissing). Never
  guessed from process existence; shown in Mac Settings and on session rows.
  One bounded exception: a ChatGPT.app-bundled `codex app-server` probe (and a
  missing `thread-writer-locks/<id>.lock`) may only *retire* an already-working
  Desktop session when that writer is gone. They must not create a session,
  move one into `working`, or change ObservationHealth.
- **Abandoned** — a Desktop session that left `working` for `done` because its
  writer disappeared (Desktop quit/crash, or the thread lock is gone). Carried
  as `summary == "Abandoned"`. Not `failed`: that flag is a real tool-error
  signal, and being abandoned is not one.
- **ChildAgent / childTopologyDegraded** — a subagent, task, or teammate under a
  parent session (`subagent:<id>` / `task:<id>` / `teammate:<team>/<name>`),
  with `running` / `completed` / `unknown`. Missing identity sets the degraded
  flag instead of inventing an id. Parent three-state is still driven only by
  parent events.
- **TaskPresentation** — the platform-neutral five-state projection used by every
  surface (Mac, iPhone, Live Activity, Widget, Buddy): `idle`, `thinking`,
  `completeUnread`, `requiresInput`, `error` (+ `unassigned` for empty slots),
  priority `error > requiresInput > thinking > completeUnread > idle`, colors from
  the Codex Micro token set. Domain state → presentation state → color token.
- **LifecycleJournal** — the bounded (7 days / 250 entries, 0600) local log of
  normalized state changes used for daemon-restart recovery and diagnostics; no
  prompts, reasoning, or tool output.
- **NotificationDelivery / NotificationDeliveryLog** — one record per local or
  APNs send with outcome `attempted` / `scheduled` / `accepted` / `failed`. Never
  `delivered`: an API result is not proof the device showed it.
- **AccountUsage** — provider quota (Codex app-server RPC, Claude `/usage` CLI):
  window, remaining, reset, freshness, `stale` / unavailable reason. Collected by
  isolated, individually switchable adapters that can never move session state.
