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

- **Buddy / Pet** — the companion character (the app icon's white cat, drawn in
  code by the Kit's `BuddyCatFace` on iOS, watchOS and macOS per ADR-0007's
  second amendment) that reflects overall status and hosts the voice companion.
  Zero third-party art.
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
- **Presence** — whether the person is at the Mac for a session:
  `PresencePolicy` (pure, in core) says *present* when the session's own
  surface (its terminal app, or Codex Desktop for a Desktop thread) is
  frontmost, the screen is unlocked and there was input within two minutes,
  unless the Settings override "Always ask the phone first" is on. Present →
  the agent's own prompt takes the answer and the phone gets a **read-only
  card** (`answerable: false`); away → the daemon holds the prompt for the
  phone. Applies to the hook gate, the question relay and app-server requests.
- **Steer** — free text for a Codex thread sent through the app-server daemon:
  `turn/steer` while a turn runs, `turn/start` when idle (a cold thread is
  resumed first). Codex threads never take typed input through a terminal.
- **Attach** — the jump for a Claude *background session* (`claude --bg`,
  agent view, Desktop Dispatch): it has no window, so `ClaudeBackgroundSessions`
  reads the supervisor's `~/.claude/jobs/<id>/state.json` (read-only) and
  `TerminalLauncher` opens the user's preferred terminal running
  `claude attach <id>` (`JumpOutcome.attached`). The job's name and "needs"
  line also fill an unnamed Claude row.
- **Dispatch** — a new task started from the phone or the Mac's "New task"
  sheet: `POST /dispatch {agent, cwd, prompt, name?}`. `cwd` must be one of the
  snapshot's `recentDirectories` (directories a session already ran in), so a
  phone can never point an agent at an arbitrary path. Claude Code starts as
  a background session (`ClaudeBackgroundLauncher`: `claude --bg [--name] --
  <prompt>` in that directory; the job's `state.json` gives the full session
  id the hooks will report). Codex goes through the app-server daemon
  (`thread/start` → `thread/name/set` → `turn/start`, the user's own
  model/approval/sandbox defaults). Other agents answer 501. The snapshot's
  `dispatchAgents` says which agents can be started right now (Claude when
  the CLI lists `--bg`, Codex when the daemon is connected); the "New task"
  entry offers only those and is disabled when there are none.
- **Question relay** — the agent's question answered from the phone or the Mac
  card through the agent's own contract: Claude's `AskUserQuestion` on a
  blocking PreToolUse hook (answered with `updatedInput.answers`, keyed by
  question text), Codex's `item/tool/requestUserInput` on the app-server
  connection (answered per question id). `QuestionRegistry` holds the wait;
  `AnswerDispatch` sends an answer there first and types into a tmux pane only
  when nothing is waiting. A `PendingQuestion` now carries every question
  (`items`), multi-select and "Other".
- **Status line sample** — one status line JSON from Claude Code, copied to the
  daemon by `hooks/vibebuddy-statusline.sh` on every event (ObservationSource
  `statusline`). It fills a known session's name, effort, cost, context, PR and
  worktree and feeds Claude's live quota (`rate_limits`); it never creates a
  session or moves the three states.
- **Live usage feed** — `AccountUsageLiveFeed`: quota that arrives on its own
  (status line `rate_limits`, the Codex daemon's `account/rateLimits/*`). The
  usage coordinator treats a live sample like a fetch and holds the spawning
  collector off while samples stay fresh (Claude 15 min, Codex 20 min).
- **Native always-allow** — a phone "Always allow" on a Claude Code approval
  echoes Claude's own `permission_suggestions` back as `updatedPermissions`, so
  Claude Code persists the rule where its terminal dialog would; the card shows
  that rule text (`Bash(npm run lint)`). The vibebuddy allow store only serves
  agents without such proposals (ADR-0010, amended 2026-09-05).
- **Approval / Answer** — the two remote actions on a session: approve/deny a
  pending permission, or inject a text answer.

## Observability (2026-09)

- **ObservationSource / ObservationHealth** — which signal currently backs a
  session (`appserver`, `hook`, `rollout`, `transcript`, `recovery`) plus its last-seen time
  and a health verdict (healthy / degraded / unsupported / eventsMissing). Never
  guessed from process existence; shown in Mac Settings and on session rows.
  One bounded exception: a ChatGPT.app-bundled `codex app-server` probe (and a
  missing `thread-writer-locks/<id>.lock`) may only *retire* an already-working
  Desktop session when that writer is gone. They must not create a session,
  move one into `working`, or change ObservationHealth.
- **Codex app-server daemon** — the shared local `codex app-server` process
  every Codex client attaches to, on `~/.codex/app-server-control/
  app-server-control.sock`. vibebuddy reads it as ObservationSource
  `appserver`, the primary Codex source while fresh (ADR-0011); it never
  starts the daemon or drives a turn from this source.
- **Thread status** — the daemon's own state for a thread: `notLoaded` (stored
  only, never surfaced), `idle` (done), `active` (working; with
  `waitingOnApproval` / `waitingOnUserInput` flags → `needsResponse`), or
  `systemError` (failed).
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
- **NotificationCategory / NotificationCategoryPrefs** — one category per
  `NotificationSound`, switched on or off per device (iPhone Settings, Mac
  Settings). Applied *after* `SoundPolicy` and before anything is posted, so a
  disabled category never reaches the phone and therefore never the Watch that
  mirrors it. The switch says *whether at all*; `SessionAttention` (below) says
  *how loud*. Defaults: approval, question, stuck, done on; long-wait
  nudge and pairing off. The iPhone uploads its copy in
  `DeviceRegistrationPayload` so the Mac's APNs push honours the phone's
  switches. The Mac's `HookParser` reads Claude's `notification_type` to set
  `waitKind` directly; the message keyword match is only the fallback.
- **SessionAttention** — how much of your attention a session has earned:
  `followed` / `normal` / `muted`. The daemon owns it: automatic `followed` for
  ten minutes after you drove the session (prompt, jump, decision, answer),
  `normal` otherwise, never automatically `muted`; a hand-set level
  (`attentionOverride`, via `POST /attention {sessionId, attention|null}` from
  the iPhone swipe / long-press or the Mac row menu / detail pane) wins and lives
  as long as the session. `effectiveAttention` is the level in force.
- **DeliveryLevel / DeliveryMatrix** — the one table from (cue × attention) to
  `bannerSound` / `banner` / `list` / `drop`, shared by the Mac's local
  notification, its APNs push and the phone's own local notification so the
  three surfaces agree. Approvals and questions interrupt at every level (a
  muted session shows them silently); a completion banners for followed and
  normal, is dropped for muted; the nudge is list-only unless followed. Quiet /
  Focus mode reads every session as `muted`; a session whose own terminal is
  frontmost is capped to `list`. `list` and `drop` never push.
- **Completion reminder** — `CompletionReminderSchedule` re-issues the
  `agentDone` cue for a `done`, unread session whose effective attention is
  `followed`, every 5 minutes, at most 12 times per completion (keyed by
  `statusSince`), on the Mac and over APNs; any acknowledgement stops it. Same
  notification id and collapse id as the original cue, so one banner is
  replaced, not stacked. The Watch carries no attention state.
- **NotificationDelivery / NotificationDeliveryLog** — one record per local or
  APNs send with outcome `attempted` / `scheduled` / `accepted` / `failed`. Never
  `delivered`: an API result is not proof the device showed it.
- **AccountUsage** — provider quota (Codex app-server RPC, Claude `/usage` CLI):
  window, remaining, reset, freshness, `stale` / unavailable reason. Collected by
  isolated, individually switchable adapters that can never move session state.
