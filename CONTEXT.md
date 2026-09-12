# vibebuddy — Domain glossary (CONTEXT)

The shared vocabulary for vibebuddy. Use these terms verbatim in issues, ADRs,
code, and tests — don't drift to synonyms.

## Core

- **Session** (`AgentSession`) — one coding-agent run on the Mac (Claude Code or
  Codex), tracked over its lifetime. Carries project, branch, model, tokens,
  context-window usage, and a **state**.
- **Current session** — a session a summary line counts and a list shows
  without being asked (`SessionCurrency` in the Kit, ADR-0017): every
  `needsResponse`, `working` or `failed` session, a followed session whose
  completion is unread, and any other session that moved within the last 24
  hours. The rest is **older**: the Mac panel folds it into an `Older` group,
  the phone offers it back with "Show N older", the Watch, the Live Activity
  and the widget leave it out. The mood line, rest line and counts on every
  surface are computed over current sessions only, so no device says "All
  quiet" while another still counts or reminds. The rule is presentation only:
  notifications, deep links, acknowledgements and the buddy's scope resolve
  against the complete set (`DashboardStore.allSessions`).
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
  `~/.codex/sessions/**/rollout-*.jsonl` event stream. Codex Desktop task/tool/completion progress enters through this local tailer
  and can also arrive through user hooks. In the 0.153.4 Desktop acceptance,
  lifecycle/tool hooks arrived but the tested escalation produced no approval
  card or rollout waiting event. Hook presence alone does not establish
  approval coverage.
- **Cursor conversation / composer** — one Cursor chat, in the IDE's Agent panel
  or in `cursor-agent`. Its **composer id** is its identity everywhere:
  Cursor's hooks send it as `conversation_id`, its transcript directory is named
  after it, and its row in Cursor's `composerHeaders` table is keyed by it. That
  one id is what lets the three Cursor sources describe one session — and, for a
  cloud agent, the Cloud Agents API too.
- **Cursor agent transcript** — `~/.cursor/projects/<flattened project path>/
  agent-transcripts/<composer id>/<composer id>.jsonl`, also the file Cursor's
  hooks name in `transcript_path`. Three line shapes and no tool results:
  a `user` line, an `assistant` line (prose plus `tool_use` blocks), and
  `turn_ended` with `success` / `error` / `aborted`. `turn_ended` is the turn
  boundary, so this is a real progress source and not a guess. vibebuddy
  **tails** it: a transcript first seen at launch starts at end-of-file and
  replays nothing.
- **Cursor composer store** — Cursor's own conversation index in
  `~/Library/Application Support/Cursor/User/globalStorage/state.vscdb`
  (`composerHeaders` on 3.x, `cursorDiskKV`'s `composerData:<id>` on every
  version), read from a private read-only snapshot. The only source for a chat's
  name, its workspace and branch, its model, its real context-token figures and
  Cursor's own `status`; conversations with no live evidence appear as
  `historyOnly` rows. Never drives the three states.
- **Cursor cloud agent** — a Cursor conversation that runs on Cursor's machines
  against a **GitHub repository**, not on this Mac against a folder. Cursor gives
  it a `bc-`-prefixed id and uses that same id as the agent id in its **Cloud
  Agents API** (`api.cursor.com/v1`). No hook fires for it, no transcript is
  written for it, and it does not appear in the composer store either, so that
  API is its *only* source — of its state and of its existence. `ACTIVE` is
  working, `IDLE` is done, `ARCHIVED` ends it; the repository stands in for the
  project, the agent's Cursor page is the jump, the runs list is the
  conversation (v1 has no `/conversation`), and a live run can be cancelled. It
  replays nothing that was already idle at launch. Needs its own
  `cursorCloudAPIKey` Keychain slot — separate from the session Cookie and from
  the CLI's own login. The shape is ADR-0011's Codex Desktop thread, not
  ADR-0016's local Cursor chat.
- **Cursor follow-up** — text the phone queues for a *running local* Cursor turn.
  Cursor cannot be interrupted or steered mid-turn, so the supplement waits and
  Cursor's own `stop` hook collects it as `followup_message`, which Cursor
  submits as the next message. One per conversation, replaced by a newer one,
  expired after 30 minutes. Continuing a *finished* Cursor chat is the other
  direction: `cursor-agent --resume <composer id>` in a terminal. A **cloud**
  agent is the mirror image: a running one refuses a follow-up (Cursor allows one
  run at a time, and answers `409 agent_busy`), and a finished one is continued
  by starting its next run over the API.
- **Cursor ACP host** — `CursorACPMonitor`: one `cursor-agent acp` process per
  conversation vibebuddy started, spoken to over stdio JSON-RPC (Agent Client
  Protocol). The live source for that conversation (`ObservationSource.acp`)
  and its write path: `session/prompt` continues, `session/cancel` stops,
  `session/request_permission` and `cursor/ask_question` / `cursor/create_plan`
  become cards. Dies with the daemon. The IDE's hooks and transcript for the
  same id only corroborate while it runs (ADR-0016, amendment 1).
- **Control channel** (`ControlChannel`) — the one write path the daemon would
  use for a session right now: `hook` (Cursor IDE, follow-ups only), `acp`
  (hosted CLI), `appserver` (Codex), `cloud` (Cursor cloud agent), `none`
  (seen, unreachable). Stamped on every snapshot; the phone's composer and the
  Watch's buttons decide what to offer from it first, from the agent second.
  Distinct from an observation source, which says how a session is *seen*.
- **Daemon** — the Mac menu-bar app's embedded HTTP + WebSocket server
  (`:9876`) that ingests hooks, runs the reducer, and broadcasts snapshots.
- **Glance** — the Mac status surface at the top of the menu-bar screen, drawn
  with the Dynamic Island's grammar (ADR-0011). On a notch Mac it never draws
  into the camera housing: **idle** (nothing), **compact** (a strip below the camera, no wider than
  the housing: the status dot left, the one primary count right), **card** (a cue unfolded below the
  housing), **expanded** (hover/click: mic + mood line, then approval or session list).
  Without a notch the same content is a **pill** hanging under the menu bar.
- **Glance card** — the glance's event layer: one `SoundPolicy` cue at a time
  shown under the housing with its actions (Approve / Deny / Jump), timed by
  `GlanceCardQueue`. While the glance is on screen the card *replaces* the
  macOS banner for session cues; hidden glance → banner as before.
- **Menu-bar entry** — a fixed cat icon that opens a panel centred under it: a
  command row you type into to narrow the list, with the voice companion's mic
  at its head; one summary line for the whole snapshot, led by the status dot
  for the most urgent state present; the snapshot in three collapsible groups —
  **Needs you / Working / Done**, newest first inside each, the phone's own list
  at panel scale (ADR-0015); and a footer row of controls (Dashboard, the Glance
  toggle, Settings, phone state, updates and quit). "Show task status in menu bar"
  optionally adds a state dot and the primary state count to the icon; it is off
  by default. The Glance owns ambient status and actionable alerts. Both
  surfaces are enabled by default and can be hidden independently.
- **Pairing** — the owner's explicit consent to link a phone to a Mac over the
  LAN, using a QR carrying the address and bearer token. A new phone needs an
  explicit, time-limited pairing window; saved phones reconnect without one.
  Historical registration without recorded consent is labeled **registered**,
  not **paired**. Forgetting removes saved phones and closes the window across
  restarts. Saved pairing does not prove current connectivity or push delivery.

## Buddy / pet

- **Buddy / Pet** — the companion character (the app icon's white cat, drawn in
  code by the Kit's `BuddyCatFace` per ADR-0007's second amendment). Since
  ADR-0017 it is a brand mark and the voice companion's avatar, not a status
  surface: it draws as the app icon, the menu-bar mark, and — only while a
  voice conversation is live — beside the mic in the phone's voice strip, the
  Mac panel, dashboard and Glance. Every status surface shows a **status
  dot** (or `moon.zzz` when empty) where the cat used to sit. Zero
  third-party art.
- **BuddyState** — the mood enum driving the pet's face and the sound pack:
  `approval`, `question`, `longWait`, `working`, `stuck`, `done`, `sleeping`.

## Voice

- **Live conversation / task backend** — the OpenAI voice companion's two roles:
  GPT-Live conducts the spoken exchange; the task backend interprets requests and
  selects tools. Interrupting speech does not cancel a coding task.
- **Voice scope** — the sessions the user included in a conversation. Reading
  status and resolving an action target stay inside that scope.
- **Voice companion** — a **realtime speech-to-speech** conversation that knows
  the live sessions and can **approve / answer** for you. Started by the same
  **mic circle** on every surface (ADR-0017 §3): the iPhone composer (always
  visible, explained once), the Mac panel's command row, the Mac dashboard's
  top bar and the expanded Glance. Its glyph follows the voice phase.
- **VoiceProvider** — a vendor the companion talks to: `qwen`, `openai`,
  `gemini`, `doubao` or `deepseek`. Each has its own key. The realtime backends
  also have a model, voice and input sample rate; `supportsVoice` says which
  ones those are, and `deepseek` is **text-only** (`voiceProviders` excludes it).
  Qwen additionally takes an optional Bailian **workspace ID**
  (workspace-specific `maas.aliyuncs.com` endpoint) and a Beijing/Singapore
  region switch; those belong to Qwen alone and move no other endpoint.
- **Purpose provider** — voice conversation, completion summaries and read aloud
  have independent choices. Summary providers must support text generation; Doubao
  is realtime-only. Read-aloud providers must have a `SpeechSynthesizer`, and
  default to following the summary provider until pinned. A valid previous shared
  summary choice is retained before changing the voice provider, and an absent or
  invalid summary choice remains unconfigured — read aloud follows it into that
  state rather than falling back to Qwen. A text-only summary provider is the
  mirror image: read aloud reports that it cannot follow one and waits for a
  pin, and a stored voice or read-aloud choice naming a text-only vendor is not
  a choice this build honors.
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
- **Steer** — free text for a running Codex turn (`turn/steer`, with
  `expectedTurnId` when known). Failure is reported; it must not fall back to
  `turn/start`. A finished session uses **continue** (`turn/start`) instead.
  Codex threads never take typed input through a terminal.
- **Stop** — end the running turn (Codex `turn/interrupt`, which requires the
  turn id the app-server connection saw start). Carries no text, is bound to
  the session's `statusSince`, and is refused rather than retried when that no
  longer matches. Codex only in this release; every other agent is stopped
  where it runs (ADR-0011, third amendment). The ending it produces is marked
  `userStopped`: Codex words a requested stop and a crash the same
  ("interrupted"), so without that mark the failure heuristic would ring the
  error cue for something the user asked for. An interruption this Mac did not
  send is unmarked and still reads as a failure. Since 2026-09-13 a Cursor
  conversation on the `acp` channel is stopped the same way (`session/cancel`,
  marked `userStopped`) and a cloud agent's run is cancelled through the API;
  a Cursor chat in the IDE still cannot be stopped from here.
- **Session action / SessionActionIntent** — what a client asks of an existing
  session: **answer** (bind to the current question), **steer** (supplement the
  running turn), **continue** (open the next turn), **stop** (interrupt the
  running turn). Distinct from Approval and from New task. The daemon re-checks
  the live question / turn before executing; an expired Answer does not become
  a steer. The client shows not-sent / sending / accepted / failed / unknown;
  accepted is not working or finished. Duplicate taps reuse a `requestId`; a
  lost receipt stays unknown and is not resent. No connection (Q16) is
  not-sent.
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
  model/approval/sandbox defaults). Cursor is hosted over ACP by
  `CursorACPMonitor` when the CLI is signed in, else opened in a terminal; a
  Cursor request may add `model`, `mode` (`plan` / `ask`; agent is the CLI's
  default and travels as nil) and `worktree` (a fresh Git worktree the CLI
  creates under `~/.cursor/worktrees/<repo>/<name>`), which become the CLI's
  global options `--model`, `--mode` and `-w` in front of `acp` or `--`.
  Model and mode must be plain tokens or the dispatch is `rejected`. Other
  agents answer 501. The snapshot's `dispatchAgents` says which agents can
  be started right now (Claude when the CLI lists `--bg`, Codex when the
  daemon is connected); its `cursorModels` is the signed-in CLI's
  `--list-models`, probed once per sign-in verdict. The "New task" entry
  offers only those agents and is disabled when there are none.
- **Question relay** — the agent's question answered from the phone or the Mac
  card through the agent's own contract: Claude's `AskUserQuestion` on a
  blocking PreToolUse hook (answered with `updatedInput.answers`, keyed by
  question text), Codex's `item/tool/requestUserInput` on the app-server
  connection (answered per question id). `QuestionRegistry` holds the wait;
  `AnswerDispatch` sends an answer there first and types into a tmux pane only
  when nothing is waiting. A `PendingQuestion` now carries every question
  (`items`), multi-select and "Other". The Watch answers a one-part question
  with the text it showed; a prompt whose every question offers choices it
  **walks** — one question per screen, the whole set sent once as
  `WatchSessionAction.answerAll` and checked by `WatchQuestionSet` on both
  sides — and a prompt with any free-text question stays on the iPhone.
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
- **Receipt** — the phone's report (`POST /notified`, `NotifiedPayload`) that it
  posted a cue's local notification itself, naming the cue's identifier and
  the wait it announced. `PhoneReceipts` holds them on the Mac; a push for a
  cue with a receipt from that phone is `skipped` (`phonePosted`) instead of
  sent (ADR-0012).
- **Push coverage** — the phone's check, before posting a *waiting* cue, that a
  delivered (or just-tapped) push with the same identifier already announced
  this wait; if so the cue is left to the push and reported as `coveredByPush`.

## Observability (2026-09)

- **RecentOutput** — a bounded, authenticated, read-only dialogue slice for one
  Session (Q31). Carries source (`transcript` / `rollout` / `appserver`),
  `updatedAt`, a truncation flag, and an unavailability reason when there is no
  dialogue to show. Thinking, full tool results, images, and terminal dumps are
  dropped; fetching it never acknowledges a completion or moves Session state.
  The phone can expand the same slice; it is not a full history.
- **ObservationSource / ObservationHealth** — which signal currently backs a
  session (`appserver`, `hook`, `rollout`, `transcript`, `recovery`) plus its last-seen time
  and a health verdict (healthy / degraded / unsupported / eventsMissing). Never
  guessed from process existence; shown in Mac Settings and on session rows.
  One bounded exception: a ChatGPT.app-bundled `codex app-server` probe (and a
  missing `thread-writer-locks/<id>.lock`) may only *retire* an already-working
  Desktop session when that writer is gone. They must not create a session,
  move one into `working`, or change ObservationHealth.
- **Codex app-server daemon** — the local `codex app-server` process on `~/.codex/app-server-control/
  app-server-control.sock`. vibebuddy reads it as ObservationSource
  `appserver`, the primary Codex source while fresh (ADR-0011); it never
  starts the daemon as part of observation. Explicit actions use its RPCs.
  Desktop can own a separate stdio app-server even at the same version; a
  connection to this socket does not establish access to Desktop-owned tasks.
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
- **NotificationCategory / NotificationCategoryPrefs** — seven device switches:
  approval (`needsApproval`), question (`needsAnswer`), failure (`agentStuck`),
  completion (`agentDone`), long-wait nudge (`longWaitNudge`), pairing
  (`pairSuccess`), and `quota` (usage / budget). The first six map to
  `NotificationSound`; quota has no sound-file counterpart. Approval, question,
  failure and completion default on; nudge and pairing default off. Quota
  defaults on for Mac, off for iPhone. Each device owns its switches; APNs
  respects the recipient phone's copy. Categories say *whether at all*;
  attention says *how loud*. Quota is independent of session attention and
  app Quiet mode / Quiet hours, and remains subject to its category switch and
  system notification settings.
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
  normal, is dropped for muted; the nudge is list-only unless followed.
  The app's Quiet mode / Quiet hours read every session as `muted`; a session whose own terminal is
  frontmost is capped to `list`. `list` and `drop` never push.
- **Completion reminder** — `CompletionReminderSchedule` re-issues the
  `agentDone` cue for a `done`, unread session whose effective attention is
  `followed`, every 5 minutes, at most 12 times per completion (keyed by
  `statusSince`), on the Mac and over APNs; any acknowledgement stops it. Same
  notification id and collapse id as the original cue, so one banner is
  replaced, not stacked. The Watch carries no attention state.
- **Missed** — one wait in `needsResponse` that reaches five minutes without
  acknowledgement on any surface, counted once for that wait even if the session
  is muted. Its time is the five-minute deadline. Mac Settings shows the current
  week's total and per-agent counts; a week begins Monday at 06:00 local time.
  A later response does not erase an already missed wait.
- **Time Sensitive cue** — an approval or question delivered at `bannerSound`.
  The interruption level is computed for each recipient after its Quiet setting;
  a silent banner is ordinary, as are all other categories. This is a request
  within the user's system notification / Focus settings, not a guarantee of
  delivery or a Critical Alert. Only remotely answerable waits carry banner
  actions: Approve (requires unlock), Deny, or text answer; a read-only wait
  remains for the Mac's native prompt.
- **PushFanout / PushRecipient** — the selected audience for a session cue,
  with each phone's final delivery level, or a shared `CueSkipReason` when no
  phone qualifies. This is the final audience vocabulary; there is no separate
  `CueAudience` type. Quota uses `QuotaNoticeFanout` because only its category
  switch governs app filtering. A selected recipient is not proof of delivery.
- **NotificationDelivery / NotificationDeliveryLog** — one record per local or
  APNs send with outcome `attempted` / `scheduled` / `accepted` / `failed` /
  `skipped`. Never `delivered`: an API result is not proof the device showed it.
  `skipped` is a cue that was earned and then not said on that channel, carrying a
  `CueSkipReason` in `failureReason` — `category`, `attention`, `quiet`,
  `focusedTerminal`, `apnsNotConfigured`, `noRegisteredDevice`,
  `phonePosted` / `pushCovered` (the other channel covers this cue), `mixed` (several
  devices, excluded for different reasons). One outcome and
  one vocabulary for both channels, so an earned cue is never simply absent from
  the log; on the push side it is decided by `PushFanout.plan`, the same pure rule
  that picks the recipients. It is not a failure and never latches the health
  diagnostic.
- **DeviceRegistry** — the Mac's owner-only, restart-surviving record of
  registered iPhones: one `DeviceRegistrationPayload` per stable identity (or APNs
  token for phones without that identity) plus
  when the phone last reported itself, bounded at 16 by newest registration.
  Held by `DeviceTokens`, written through on every `POST /device`. A token
  leaves on **410 Unregistered**, and on **400 BadDeviceToken only if Apple has
  never once accepted a push for it** (junk: a typo, a test fixture, the wrong
  APNs environment) — a 400 on a previously accepted token means *this Mac* is
  misconfigured and the device is kept. Never on age, since a phone that has
  been off for a month still has a valid token. The phone
  re-reports on every dashboard connection, not once per launch, so a Mac
  restart is repaired by the next reconnect rather than by a cold launch.
  Identified phones can be saved before APNs registration; push counts include
  only records with a token. Expiring a push token retains the phone identity,
  so push availability never decides whether that phone is paired.
- **AccountUsage** — provider quota (Codex app-server RPC, Claude `/usage` CLI,
  Cursor/Grok local sources): window, remaining, reset, freshness, `stale` /
  unavailable reason, plus extra named windows (Claude model-week, Codex Spark),
  credits remaining, and extra-usage spend when the local source reports them.
  Collected by isolated, individually switchable adapters that can never move
  session state. Extra windows never replace the weekly remaining slot.
  Distinct from **Token consumption** (local spend ledger) and from billed invoices.
- **Token consumption** — local, read-only aggregation of tokens spent in Claude
  Code transcripts and Codex CLI/Desktop rollouts (input, output, cache-read,
  reasoning), grouped by agent, model and project over today and the last seven
  days. Distinct from **AccountUsage** (quota remaining) and from a Session's
  current-turn `tokens` / cumulative `spentTokens`. Composed into the snapshot
  beside quota; never feeds the session reducer and never leaves the machine.
- **Grok Bot** — the cloud bot product opened by `com.anysphere.sand`, distinct
  from Grok Build CLI (`grok`). Its account quota has the independent `grokBot`
  provider identity. The optional Mac observer uses the official client's
  active-account gateway credentials for read-only observations; it does not
  start tasks or answer questions. A Session belongs to account + bot, and a
  completion additionally belongs to the initiating turn. Message IDs alone
  are insufficient because different bots can reuse them.
- **Grok Bot gateway** — `ObservationSource.gateway`. Connection health is
  separate from task state: reconnecting or losing access does not prove that
  a task finished. User-visible final replies must match the initiating user
  request and its terminal settlement before entering completion summaries.
  Without a verified exact-bot jump, Jump opens the official app. Foreground
  Grok Bot can suppress speech but does not acknowledge every bot's completion.
  A current unanswered native `widget` is needsResponse even when the roster
  reports idle and an old successful settlement. Answering the widget may start
  a new request without a new associated settlement; this continuation's completion
  is currently unverifiable and keeps degraded observation health. It must not
  inherit the earlier turn's success or enter summaries by temporal proximity.

## Completion summaries and Mac reading

- **Conversation summary** — a user-requested reading aid for one historical
  conversation, separate from a Completion notice. It summarizes bounded readable
  history through the configured BYO text provider, excludes injected Meta and
  Thinking, and records coverage and source revision. A changed source marks the
  persisted result stale. Generating or reading it establishes no live completion
  identity, notification or task control capability.
- **Completion notice** — the Mac's durable wording decision for one
  source/session/completion: pending, plain, summary, or cancelled. Only the
  final assistant result bound to that completion may be summarized. Pending
  does not change session state or delay permission/question cues. The Mac
  commits the decision by completion + 12 seconds; an updated phone waits for
  that decision rather than independently choosing competing wording.
- **Read aloud (Mac)** — a separate opt-in which synthesizes the initial AI
  completion summary through the `SpeechSynthesizer` protocol and plays it on the
  Mac's current output. Its provider follows the completion summary provider
  unless pinned; model and voice are stored per provider, prefilled, and have a
  sample preview. It does not open a microphone, replay completion reminders, or
  speak over a voice call. Generation/notification acceptance, player completion
  and human hearing are separate evidence. iPhone headphone announcements remain controlled by Siri.
- Phones advertise `supportsCompletionNotices` when registering. Existing
  installed clients retain their ordinary completion copy and identity until
  they implement the pending/decision protocol.

Mac presence suppresses ordinary cues only while the verdict is current; leaving restores one still-open wait reminder without making the card remotely answerable.

- **Copilot history** — Wake-compatible read-only conversations from
  `~/.copilot/session-store.db` (`sessions` + `turns`). The scanner checks the
  database and WAL every five seconds and reads private temporary copies.
  History rows bypass SessionReducer, carry `historyOnly: true`, and use the
  existing quiet `.done` wire value with no completion identity or unread flag.
  They do not establish live status or generate completion notices; clients
  label them History. RecentOutput carries a bounded dialogue slice. As `done`
  rows dated by their history time they are current for a day and then older,
  like any other finished session.
