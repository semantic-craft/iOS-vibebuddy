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
- **failed / stuck** — a confirmed terminal failure. A tool error while a turn
  continues is recovery activity, not a request for human intervention. Lost or
  unreadable observation is uncertainty, not a terminal outcome.


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
  Agents API** (`api.cursor.com/v1`). This Mac's user hooks and local transcript
  watcher do not observe its remote execution; the composer store is not reliable
  for discovering it. The API is VibeBuddy's configured cloud source. Cursor also
  supports repository command hooks in cloud environments, separately from local
  user hooks; VibeBuddy does not collect those remotely (ADR-0018). `ACTIVE` is
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
  become cards. Normal shutdown terminates the child process; after an abnormal
  host exit, recovery requires confirmation that the old process has ended.
  Minimal private metadata permits lazy `session/load` after restart. A recoverable row
  is not a live ACP channel and offers only Continue until loading succeeds.
  The IDE's hooks and transcript for the
  same id only corroborate while it runs (ADR-0016, amendment 1).
- **Grok ACP host** — `GrokACPMonitor` (ADR-0030): one `grok agent --no-leader
  stdio` process per Grok Build session vibebuddy started, spoken to over stdio
  JSON-RPC. The live source for that session (`ObservationSource.acp`) and its
  write path: `session/prompt` continues, a supplement for a running turn waits
  in the follow-up queue and goes out as the next prompt (Grok has no interject
  extension), `session/cancel` stops, `session/request_permission` and
  `_x.ai/ask_user_question` become cards. The ACP `sessionId` is the session
  directory name and the id Grok's hooks report, so hooks and the directory
  enrichment corroborate the same row and the `/approval` gate stays silent for
  it. A denied permission ends the turn as `cancelled`: `done`, not `failed`,
  not `userStopped`. The session's permission frequency is the user's own
  `[ui] permission_mode`; under `always-approve` no card appears. A Grok
  session opened in a terminal is unchanged (hooks observe, the phone says to
  use the terminal). After a daemon or app restart a hosted session comes back
  as a reloadable row (`GrokACPRecovery`, ADR-0030 amendment 1): Continue
  reloads it with `session/load` in a new process; if that fails, opening it on
  the Mac runs `grok --resume=<id>` in a terminal, which owns it from then on.
- **Control channel** (`ControlChannel`) — the one write path the daemon would
  use for a session right now: `hook` (Cursor IDE, follow-ups only), `acp`
  (hosted Cursor or Grok Build CLI), `appserver` (Codex), `cloud` (Cursor cloud agent), `none`
  (seen, unreachable). Stamped on every snapshot; the phone's composer and the
  Watch's buttons decide what to offer from it first, from the agent second.
  Distinct from an observation source, which says how a session is *seen*.
- **Daemon** — the Mac menu-bar app's embedded HTTP + WebSocket server
  (`:9876`) that ingests hooks, runs the reducer, and broadcasts snapshots.
- **Glance** — the Mac status surface at the top of the menu-bar screen, drawn
  with the Dynamic Island's grammar (ADR-0011). On a notch Mac it never draws
  into the camera housing: **idle** (the physical housing only), **compact** (compact status wings
  beside the camera, at the physical housing height), **card** (a cue unfolded below the
  housing), **expanded** (hover/click: mic + mood line, then approval or session list).
  Without a notch the same content is a **pill** hanging under the menu bar.
- **Glance card** — the glance's event layer: one `SoundPolicy` cue at a time
  shown under the housing with its actions (Approve / Deny / Jump), timed by
  `GlanceCardQueue`. While the glance is on screen the card *replaces* the
  macOS banner for session cues; hidden glance → banner as before.
- **Agent rail** — the dashboard's leftmost 48 pt column (`DashboardAgentRail`,
  ADR-0031): one tile per agent reporting in the current window, led by **All
  agents**, each ringed by that account's tightest allowance (`AgentQuotaReading`)
  and dotted when one of its sessions needs you, with Settings at the foot.
  Choosing a tile is the window's first axis; it sets the live list's agent.
- **Agent column** — the column beside the rail (`DashboardSidebar`,
  ADR-0031): the chosen agent's workspace — its name and allowance, **New
  \<agent\> task**, the voice rows, the five libraries, and its live sessions
  grouped by **Needs you / Working / Unread results / Idle**
  (`DashboardAgentColumn`), with a project pill and the search field over them.
  The libraries stay fleet-wide; only the sessions below them are the agent's.
- **Agent strip** — the iPhone hub's own first axis (`PhoneAgentStrip`,
  ADR-0031): the rail's entries in a horizontal row under the Inbox title,
  each a brand mark inside its allowance ring with an attention dot and its
  session count, **All** leading. The choice scopes the hub's mood line, First
  up, tiles and projects (`InboxProjection(sessions:now:agent:)`), carries into
  the list page and into New task, and survives Back. `AgentRoster` (Kit) is
  the one place both the rail and the strip get their tallies.
- **Allowance strips (Watch)** — the wrist's quota section (`WatchQuotaStrips`,
  ADR-0031 §9): one row per **independent pool** carrying that **agent's** mark
  and its short name — or the pool's own name where a provider has several
  (`stripWindows`) — lowest reading first by the number the row itself shows
  (`stripRowsLowestFirst`), unreadable ones last. The list is flat and ordered
  by rows, not grouped by provider: a Cursor pool with room must not ride above
  another agent's tighter row just because its sibling is nearly spent. The Watch takes no agent
  axis — its order is already attention-first (ADR-0021) — but a reading at or
  below `QuotaReading.lowRemainingPercent` follows the agent onto the alert
  card and the task header as "· N% left" in the attention tint.
- **Right slot** — the dashboard detail column's one place for a session's
  records that are not the conversation, after Cursor's right sidebar
  (`RightSlotState`, ticket 11): the **shelf** (the `On <project>` rows —
  Changes with its `+N`, Output, Activity), a **pane** (one row opened in
  the shelf's place, tabs to switch, expand / close), or the **rail** (the
  slot hidden to a floating strip; ⌥⌘B). The reading column keeps the
  result and the decision; the foot keeps the request's keys or the composer.
- **Menu-bar entry** — a fixed cat icon that opens a panel centred under it: a
  command row you type into to narrow the list, with the voice companion's mic
  at its head; one summary line for the whole snapshot, led by the status dot
  for the most urgent state present; the snapshot in three collapsible groups —
  **Needs you / Working / Done**, newest first inside each, the phone's own list
  at panel scale (ADR-0015); and a footer row of controls (Dashboard, the Glance
  toggle, Settings, phone state, updates and quit). "Show task status in menu bar"
  optionally adds a state dot and the primary state count to the icon; it is on
  by default when no explicit choice has been saved. The Glance owns ambient status and actionable alerts. Both
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
- **Named target** — a voice task action (approve, deny, answer, instruct) is
  sent only when the user's own words in the current exchange name its target;
  otherwise it is **held** and the user is asked to say the name (ADR-0008).
- **Voice companion** — a **realtime speech-to-speech** conversation that knows
  the live sessions and can **approve / answer** for you. Started by the same
  **mic circle** on every surface (ADR-0017 §3): the iPhone composer (always
  visible, explained once), the Mac panel's command row, the Mac dashboard's
  sidebar (its Voice row) and the expanded Glance. Its glyph follows the voice phase.
- **VoiceProvider** — a vendor the companion talks to: `qwen`, `openai`,
  `doubao` or `deepseek`. Each has its own key. (Gemini was removed on
  2026-09-25, ADR-0001; the agent source `gemini` is Antigravity, not a
  VoiceProvider.) The realtime backends
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
  audioDelta, speechStarted, responseDone, failed, providerLimitReached,
  closed) that the audio + UI layers consume.
- **Provider limit / redial** — a provider's per-connection cap (session
  duration) ending a call. Only an explicit provider signal counts
  (`ProviderLimitSignal`); an unrelated disconnect stays a failure. The call
  ends as `ended(providerLimit)` — a notice, not an error — and **Redial**
  starts a fresh call with the same Settings and no carried-over conversation
  (ADR-0001).
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
  ("interrupted"), so without that mark its terminal failure signal would ring the
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
  reads `claude agents --json --all` (the documented interface; background
  entries only, fields decoded as they appear) and `TerminalLauncher` opens the
  user's preferred terminal running `claude attach <id>`
  (`JumpOutcome.attached`). The job's name and its "needs" line (`waitingFor`,
  or that job's own `needs` when the CLI omits it, as 2.1.280 does) also fill
  an unnamed Claude row. `ClaudeAgentsSource` runs the command on its own
  queue, one refresh at a time, only when a stat fingerprint of
  `~/.claude/jobs` changes or 60 s have passed; synchronous readers never wait,
  and a jump or a launch refreshes it off the main actor. Without the command
  it falls back to the jobs files. Hooks remain the authority for state.
- **Dispatch** — a new task started from the phone or the Mac's "New task"
  sheet: `POST /dispatch {agent, cwd, prompt, name?}`. `cwd` must be one of the
  snapshot's `recentDirectories` (directories a session already ran in), so a
  phone can never point an agent at an arbitrary path. Claude Code starts as
  a background session (`ClaudeBackgroundLauncher`: `claude --bg [--name] --
  <prompt>` in that directory; `claude agents --json` maps the printed job id
  to the full session id the hooks will report). Codex goes through the app-server daemon
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
- **Held decision** (ADR-0032) — an approval or answer the phone accepted and
  could not give the Mac: kept in `SessionActionQueue` (`PendingActionStore`
  on disk), one per target, a later decision replacing the earlier one, never
  a stop. Its id is the idempotency key end to end — the wrist's `attemptId`,
  the `requestId` on `/decision` and `/answer`, the Mac's `ActionRequestLog`
  entry — so a retry after a lost receipt cannot apply twice. Delivered on
  reconnect, on a push wake, or on *Retry* from the Inbox; reported as held /
  delivered / gone / dropped on the surface the tap came from (a `queued`
  reply with a `reason` on the wrist, a notification replaced in place for
  the banner, a toast in the app). Beside it, **the missing link**
  (`ConnectionFailureReason`): `tailnetOff` when the pairing is a
  `100.64.0.0/10` address and no interface on the phone carries one,
  `macUnreachable`, `authentication`, `invalidAddress`, `dropped` — named on
  the phone's screens with the tap that fixes it (open Surge / Tailscale).
- **Status line sample** — one status line JSON from Claude Code or Grok Build
  (`/statusline?agent=grok`), copied to the daemon by
  `hooks/vibebuddy-statusline.sh` on every event (ObservationSource
  `statusline`). It fills a known session's name, effort, cost, context, PR,
  worktree and branch and feeds Claude's live quota (`rate_limits`; Grok sends
  none); it never creates a session or moves the three states. A sample
  identical to the last one within 30 s is skipped.
- **Grok session registry** — `<grok home>/active_sessions.json`, Grok's own
  list of open `grok` processes. A session the daemon saw listed whose process
  has since exited is ended at the next sweep as its `SessionEnd` would have
  ended it; absence alone proves nothing, and while a Grok leader answers
  (sessions outlive their terminal) nothing is retired.
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
  Settings diagnostics cover Claude, Codex, Grok and Cursor (hook, transcript,
  hosted ACP, cloud), reading config directories where the hook installer
  writes them (`CLAUDE_CONFIG_DIR`, `CODEX_HOME`, `CURSOR_HOME` honoured).
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
  muted session shows them silently); a followed completion uses banner and sound,
  a normal completion uses a silent banner, and muted completions are dropped;
  the nudge is list-only unless followed.
  The app's Quiet mode / Quiet hours read every session as `muted`; only a positively
  identified current task view can cap its cue to `list`. Source-app presence alone
  cannot identify the viewed task. `list` and `drop` never push.
- **Background work at a Claude Stop** (AI-04) — Claude's main-agent `Stop`
  carries `background_tasks` and `session_crons` when its task registry is
  reachable; when present they are the truth, even empty. Running subagents,
  workflows or teammates make the `Stop` a pause: the session stays `working`
  (row: background tasks running) and the reducer holds the `Stop`. Only when
  the arrays are absent do running subagents in the child topology stand in;
  task-list entries (`TaskCreated`) never do, and an interrupted or failed main
  turn marks its running subagents unknown. A turn held only by subagents moves
  to a 45-second grace once as many `SubagentStop`s as it awaited have arrived
  and none still runs. Only a stop that ends a subagent seen starting counts:
  the CLI's internal agents stop without a `SubagentStart`, and a real
  subagent whose start was lost keeps the turn until a newer `Stop` or the
  backstop (AI-09). The main agent usually continues within the grace and its
  own `Stop` replaces the held one. Workflows and teammates report no end, so only
  a newer `Stop` or the ten-minute backstop releases them. The sweep settles a
  due `Stop` through the normal path, stamped with the release time; a new
  turn, a wait or a new session discards it. Claude sessions restored as
  `working` after a daemon restart retire quietly (`probeRetired`) if no event
  arrives within the backstop. Running shells, monitors, MCP tasks and cloud
  sessions do not hold the turn: it completes and the row says background
  tasks are still running (`backgroundTaskCount`). A recurring `session_crons`
  entry marks the ending `loopScheduled`: it settles `done` with no completion
  identity, no unread badge and no `agentDone` cue, because a `/loop` session
  always has one; a one-shot reminder does not. A main-agent `PostToolUse` that
  lands after the `Stop` settled cannot reopen the turn.
- **Completion reminder** — `CompletionReminderSchedule` re-issues the
  `agentDone` cue for a `done`, unread session whose effective attention is
  `followed`, after 5, 10, 20 and then 40 minutes — at most 4 times per
  completion (keyed by `statusSince`), the last 75 minutes after it — on the
  Mac and over APNs; any acknowledgement retires it for that completion, even when later marked unread. Same notification id and
  collapse id as the original cue, so one banner is replaced, not stacked.
  The cadence backs off because every reminder is mirrored to the wrist as a
  fresh buzz (ADR-0021). The Watch carries no attention state.
- **Watch results** — the bounded current result payload on the wire
  (`WatchDashboardState.results`: failures and unread completions in
  **pending queue** order, ADR-0022, a subsequence of the phone's queue; at
  most six). Failures sit under *Also waiting*; unread results have their own
  clickable rows on Watch home. Current working
  sessions are also openable, whether followed or normal. A mirrored notification
  can target the same exact task. A completion
  summary is not the full result: opening it leaves the round unread and its
  reminder budget intact. **Mark as read** on a Watch task explicitly confirms the displayed
  source/session/completion. Offline
  intent remains pending until the Mac confirms; opening a wait only marks
  that wait seen (ADR-0021 and its 2026-09-14 amendment).
- **Banner action** — a button on a notification (Approve, Deny, Reply). All
  are foreground actions, so Apple runs one on the device it was tapped on
  (ADR-0033). On the Watch the tap is mapped by `WatchNotificationResponseRoute`
  and sent through the card's own action path; when it cannot be sent, the card
  says why (`WatchBannerActionFallback`). A Reply is bound to the question its
  notification names (`questionId`, like `approvalId` for Approve); if the
  agent has moved on it is refused and the words stay on the card. On the phone
  it lands on the session.
  Distinct from the *default tap* on the notification body, which only opens.
- **Recap** — removed on every device (2026-09-26, ADR-0028 amendment). There
  is no record of ended rounds, recap horizon, `/recap-read` or Recap page on
  Mac, iPhone or Watch; unread results and *All sessions* remain the way back
  to a round.
- **Next pending** — an explicit navigation step through Needs you, then unread
  Done, using the same priority and stable newest-first order on Mac and iPhone.
  The iPhone and Mac detail footer follow the scope they entered from (ADR-0022): the
  whole snapshot from **First up**, the bucket or project from a list page,
  plus query and Older; iPhone additionally retains Customize picks. The footer names that scope
  and the current position (`All sessions · 2 / 5`), or explains that the selected
  result is no longer pending. Grouping and collapse do not
  narrow the tour or change the global counts.
  Reading the current result never moves the page, and removing that result from
  unread does not restart the tour at an unresolved wait. Navigation itself
  neither acknowledges results nor resolves waits.
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
  Held by `DeviceTokens`, written through on every `POST /device`. A phone is
  **parked** (kept on file, listed with Apple's reason, no longer pushed to) on
  **410 Unregistered**, on **400 BadDeviceToken if Apple has never once
  accepted a push for it** (junk: a typo, a test fixture, the wrong APNs
  environment), and on a **run of 400 BadDeviceToken on a once-accepted token
  that spans a day with nothing accepted in between** (`DevicePushFailure`,
  `DevicePushFailurePolicy`) — a single such 400 still points at *this Mac*
  being misconfigured and is only counted. Parking writes one **`pruned`** row
  to the delivery ledger, naming the phone and Apple's reason, instead of a
  `failed` per push. The phone reporting a push token again revives it; the
  run is remembered, so if Apple still refuses, the next send parks it again.
  Never on age, since a phone that has
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
  session state. A **scoped window** (Claude model-week, Codex Spark) is a
  subdivision of the same allowance, not a pool of its own: it rides
  `scopedWindows`, shows only in the Mac Account usage list and the iPhone
  Usage page, and is deliberately absent from `otherWindows` — the slot the
  Watch strip and the widgets fall back to — and from threshold alerts, which
  stay on the weekly and short windows (one cue per event, ADR-0012).
  An **independent pool** is the opposite: an allowance that can stop work on
  its own. Cursor reports two of them over one billing period — `Cursor Models`
  and `Other Models` — and neither stands in for the other, so every surface
  with room lists both, and a surface with room for exactly one (a ring, an
  `accessoryCircular` widget) draws the tightest and names it. A pair is
  several pools over **one period**; the relayed `ProviderQuota.samePeriodPools`
  and the Mac's `AccountUsageSnapshot.independentPools` run that identical test
  on their own window types, so the two sides cannot disagree about what a pair
  is, whichever slot the projection filed a pool under. The Mac's one-number
  surfaces read `headlineWindows`, which is `quotaWindows` and never
  `displayWindows`: a scoped week at 95% used must not ring the Mac at 5% while
  the wrist reads the real week. What a list shows and the order it shows it in
  stay defined together, so a row reading 31% never sits below one reading
  41%.
  The iPhone Usage page and its home- and lock-screen quota widgets consume the
  same `ProviderQuota`: the page reads the live dashboard and keeps the Kit's
  15-minute stale rule; the widgets read a `PhoneQuotaSnapshot` the app writes
  to the App Group, print the reading's age, and fade only when the phone last
  saw the Mac unreachable or the reading is over an hour old. A widget tap is
  `vibebuddy://quota/<provider|all>`.
  Distinct from **Token consumption** (local spend ledger) and from billed invoices.
- **Token consumption** — local, read-only aggregation of tokens spent in Claude
  Code transcripts and Codex CLI/Desktop rollouts (input, output, cache-read,
  reasoning), grouped by agent, model and project over today and the last seven
  days. Distinct from **AccountUsage** (quota remaining) and from a Session's
  current-turn `tokens` / cumulative `spentTokens`. Composed into the snapshot
  beside quota by both the menu-bar app and headless `vibebuddyd`; never feeds
  the session reducer and never leaves the machine. Transcripts are read on a
  utility task behind a size+mtime memo, so a refresh costs the files that
  actually changed.
- **Grok Bot** — the cloud bot product opened by `com.anysphere.sand`, distinct
  from Grok Build CLI (`grok`). It is an **account-usage provider only**
  (ADR-0031): the independent `grokBot` provider identity reads the signed-in
  account's Sand allowance, and nothing else. There is no task observation, no
  Session, no jump and no approval path — `AgentKind.grokBot` exists so a quota
  row can carry the brand mark, and a `?agent=grokbot` hook is rejected rather
  than mistaken for another CLI. `ObservationSource.gateway` and
  `WaitHandling.macGrokBot` remain in their wire enums only so a snapshot
  written by an older build still decodes; nothing produces them.

## Completion summaries and Mac reading

- **Content style** — the source Mac's global content preference (`contentStyle`
  and `contentStyleCustomPrompt`): *concise* leads with the one thing the reader
  can do now (only when the record asks for it) or the most important perceptible
  result, and ends with at most one next step; *decision* gives a nontechnical CEO
  briefing on outcomes, benefits and supported tradeoffs; *custom* applies up to
  2000 characters of expression instructions. All styles share the reader-shaped
  writing rules (no preamble or closer, current state stated, user steps spoken
  in order rather than numbered, at most five visible items per group,
  matter-of-fact failures, time only when the record gives it) and the evidence
  and authorization rules; the prompt fingerprint is `content-prompt-v2`.
  Settings and the Voice and reading panel use this same choice. Paired phones
  read and update it through authenticated `/content-style`; optimistic revision
  checks prevent a stale phone edit overwriting a newer choice. Voice/persona
  preferences remain independent and local to their provider.
- **Content presentation** — derived wording generated directly from the original
  evidence, through the summary provider. Notice and speech share
  content rules but have distinct length limits: 180 and 900 characters.
  Speech uses an independent bounded cache, keyed by source, exact round,
  evidence, purpose and effective provider/language/style configuration. These
  requests never claim or redeliver notifications, acknowledge results or act on
  tasks. `/presentation` resolves evidence on the Mac and rejects stale source,
  round or configuration after generation. Snapshot carries the effective revision
  without broadcasting the custom prompt. Failed generation uses explicit limited
  fallback wording. Completion speech additionally requires verified result
  evidence for that exact round; without it, there is no spoken ending. Speech
  uses the conversation name when available. Codex final-answer text alone does not
  end a turn: the native terminal event must arrive, and a hook Stop cannot
  close a turn the rollout still reports as active. Claude speech also waits for
  the matching final response's completed Stop-hook summary without continuation
  feedback. Cursor hook results are read only from transcript bytes observed
  after the prompt, ending in success; a following prompt or handed-over follow-up
  invalidates that speech. If summary generation fails after verification, speech
  reads a named excerpt from the verified result instead of an unavailable-summary
  completion message. Notification summary generation waits for the same native
  settlement evidence and rechecks it before publishing; unverified expiry is
  silent. There is no additional completion-reminder throttle.
  Automatic reading still requires its opt-in; manual reading
  can request content even when automatic completion summaries are off.
- **Completion result evidence** — the exact source/session/completion UUID and
  its native turn identity, or Claude's observed prompt boundary. A newly
  observed authoritative Codex ending can establish its UUID-to-turn mapping
  before the start boundary or text arrives; an existing legacy UUID cannot be
  assigned from a later ending. `CompletionResultLedger`
  (`completion-results.json`) keeps the result index (seven days, at most 512
  records and 8 MiB encoded result data, 12,000 characters per body). Reads recheck
  expiry. Codex recovery reads an explicitly named successful turn from a bounded
  transcript scan; Claude's successful Stop text can be used before its transcript
  flushes. Missing evidence remains unavailable, never the last assistant message
  from another round. Differing text permanently marks the identity as conflicted:
  the first body remains diagnostic evidence, while ordinary reading, generated
  presentation and automatic reading refuse it. A repeated first body cannot
  clear conflict. Recovery never restores notification capture, changes current
  progress, or acknowledges a result. Clear timeline retains its diagnostic scope;
  result retention follows the result index's own expiry and capacity policy.
  Internal presentation diagnostics distinguish unavailable evidence, unreadable
  sources and provider/output failures without recording bodies or credentials.
- **Completion notice** — the Mac's durable wording decision for one
  source/session/completion: pending, plain, summary, or cancelled. Only the
  final assistant result bound to that completion may be summarized. Pending
  does not change session state or delay permission/question cues. The Mac
  commits the decision by completion + 12 seconds; an updated phone waits for
  that decision rather than independently choosing competing wording.
  Restored pending decisions are cancelled. Notification senders recheck the
  current decision before delivery. Offline completion speech on iPhone uses
  only a saved summary validated against the current source and completion,
  with the conversation name; unresolved decisions do not fall back to progress text.
- **Read aloud (Mac)** — a separate opt-in which synthesizes an attributed result
  or confirmed blocker announcement through the `SpeechSynthesizer` protocol and plays it on the
  Mac's current output. Its provider follows the completion summary provider
  unless pinned; model and voice are stored per provider, prefilled, and have a
  sample preview. Voice and announcer style are editable at the top of Voice
  settings and in the Voice and reading panel, using the same per-provider
  preferences. Changes apply to the next reading without stopping the current
  announcement. Providers without style support show a disabled Standard choice
  with an explanation. It does not open a microphone, replay completion reminders, or
  speak over a voice call. Generation/notification acceptance, player completion
  and human hearing are separate evidence. iPhone headphone announcements remain controlled by Siri.
- Phones advertise `supportsCompletionNotices` when registering. Existing
  installed clients retain their ordinary completion copy and identity until
  they implement the pending/decision protocol.

Notification suppression requires a positively identified task view (currently the active VibeBuddy task view), not merely the source app being frontmost. Unknown Codex/terminal tab identity does not silence a followed task. Leaving the identified view restores one still-open wait reminder without making the card remotely answerable. App-level Presence remains an independent approval-routing signal.

- **Copilot history** — Wake-compatible read-only conversations from
  `~/.copilot/session-store.db` (`sessions` + `turns`). The scanner checks the
  database and WAL every five seconds and reads private temporary copies.
  History rows bypass SessionReducer, carry `historyOnly: true`, and use the
  existing quiet `.done` wire value with no completion identity or unread flag.
  They do not establish live status or generate completion notices; clients
  label them History. RecentOutput carries a bounded dialogue slice. As `done`
  rows dated by their history time they are current for a day and then older,
  like any other finished session.

- **Session key** — an agent-prefixed native session identity, such as
  `claude-code:<id>`, `codex:<id>`, `cursor:<id>` or `grok-build:<id>`.
  Different agents may use the same native ID without sharing an identity.
- **Session reference** — `vibebuddy://session/<key>#<seq>`, pointing to a one-based
  transcript record in the reported source revision (`vibebuddy-mcp show`). It is
  not a permanent reference across source changes; hidden Thinking records retain
  their sequence. There is no archive or search behind it: the History archive was
  removed on 2026-09-23 (ADR-0019 amendment).
- **Session reader** — the dashboard's right column (`SessionReaderPane`,
  ADR-0024): a two-line head with the session's controls top-right, one row of
  jumps, the conversation body (`SessionReaderView`, newest page first, tools
  and thinking folded), and a dock for the pending decision or the composer.
  It shows live sessions only. Reading confirms nothing: only the result card
  at the end of the body (the daemon's `completionBody`) can mark a round read.
- **Reader source** — where the reader's body comes from
  (`SessionReaderSource`): the agent's own local transcript by exact key
  (`<key name>:<native id>`), read by `SessionTranscriptReader` straight from
  the file under the agent's roots — no cache, index or writes — else the
  daemon's bounded *recent output* labelled as an excerpt. A transcript is never
  matched by title. The open transcript's file is watched; live state comes only
  from the snapshot. The same reader serves the phone's `/history` pages and
  `vibebuddy-mcp show`.
- **Live status (tool)** — a read-only observation of current sessions grouped
  by checkout, excluding the caller's known identity. It is a collaboration hint,
  not a lock; an unreachable daemon means unknown, not idle.
- **Handoff note** — the writer's task context and remaining work under
  `.scratch/<feature>/handoffs/<yyyy-mm-dd>-<from-agent>-<to-agent>.md`.
  Its first line, `Source session: <key>`, names the writer's own verified Session
  key, or `unknown` when unavailable; the newest project session is not evidence
  of authorship. A transcript read cannot override a newer Handoff note. Since
  ADR-0023 the note opens with the **Handoff facts** block and its Verification
  evidence has two parts: what the facts show ran, and what the writer concludes;
  anything the facts do not support is `[unverified]`.
- **Handoff facts** — `vibebuddy-mcp facts <key>` (`vibebuddy_handoff_facts`):
  the Mac's recorded facts for one session, printed as the note's four header
  lines plus a `## Facts (recorded by VibeBuddy, as of <time>)` section — rounds
  ended, live git HEAD / branch / changed paths, files edited, commands run with
  exit codes, a coverage line naming what the session's observation path could
  report (hook and Codex app-server: commands and exit codes; Cursor ACP and the
  rollout tailer: tool names only), and a data-freshness line. Read from the
  lifecycle journal and tool ledger without writing; git is probed read-only. Tool
  calls require recorded agent identity; unqualified older calls are omitted with
  coverage stated. Only confirmed successful edits establish edited files. The
  caller supplies its own key; a bare native id resolves only when one agent
  recorded it, "Not recorded" is an answer (exit 0), not an error.
- **Handoff record** (`HandoffRecord`) — a Handoff note the Mac found by scanning
  `.scratch/*/handoffs/*.md` under the snapshot's recent directories: its path,
  the parsed header (source key nil for `unknown`), when it was written and the
  Session keys of receivers the Mac started from it (`takenBy`, derived from the
  Continuation records). Carried as `snapshot.handoffs`; the file remains the
  only truth. A session row whose key a record names shows **Handoff ready**.
- **Continuation record** — one line in the Mac's `continuations.json`
  (owner-only, seven days from `recordedAt`): `receiverKey`, `sourceKey`,
  `handoffPath?`, `recordedAt`, written by the dispatch layer (Mac app or
  `POST /dispatch`) when a Continue with… task starts. A session's
  `continuesSessionKey` and a Handoff record's `takenBy` derive from these
  records; `facts` prints the receiver's `Continues:` line from them, before
  the receiver's first hook. The lifecycle journal stores none of it.
- **Recent directories** (`recentDirectories`) — the directories sessions ran
  in, newest first; the only places a task may start. Kept in
  `recent-directories.json` together with each session's observed checkout,
  so both survive a restart; a journal-restored session gets its own checkout
  back or none. A folder with the same last name is never used as a match.
- **Continue with…** — a finished session's action on the Mac (row context menu,
  detail title bar) that prefills the New task sheet for one of `dispatchAgents`:
  the session's observed checkout (empty when the Mac never observed one),
  `Continue: <title>`, and a first prompt of `Read <handoff path>, then
  continue.` + `Continues: vibebuddy://session/<key>` (or, with no record, the
  `Continues:` line and a pointer to `facts` / `show`). When the handoff's
  effort directory lies outside the checkout the prompt adds one fallback line
  ("if your sandbox refuses to write there, report the text instead"). The
  person reviews and presses Start; the writer's session is untouched. The
  sheet says when other sessions are working in that folder and offers another
  folder (and Cursor's fresh worktree); it never switches on its own. The
  request carries a `continuation {sourceKey, handoffPath?}`; the dispatch
  writes the Continuation record and, for a Codex thread whose own policy is
  workspace-write, appends the handoff's `.scratch/<feature>/` to
  `writableRoots` on `turn/start` — the thread's default for the rest of that
  task, and nothing else widened.
## iPhone inbox (2026-09-13, ADR-0022)

- **Inbox** — the iPhone home and Mac Dashboard default entry: the mood line, **First up**, four **buckets**,
  the **Projects** list and, on iPhone, the composer. Mac opens its existing
  task list/detail workspace. Every number is the current-session
  summary the Mac panel and the Watch also read. Read results have no bucket;
  they are reached through *All sessions*.
- **Bucket** — one of the four tiles, a slice of the current sessions by
  presentation state: *All sessions*, *Unread results* (`completeUnread`),
  *Needs you* (`requiresInput` + `error`; worded **Stuck** while only
  confirmed failures are in it), *Working* (`thinking`). Tapping one opens the
  **bucket page**. On iPhone this has the scope's name as the title, a *Recents* group and then
  the same rows under their projects, two lines per row, no inline keys.
  Search on that page matches title, project and branch.
- **First up** — the head of the **pending queue** (`PendingTasks.ordered`
  over every current session). The same task is the Watch's first card and
  the first item read aloud. Opening it never marks anything read.
- **Pending queue** — the one order every surface walks: questions and plan
  decisions, then approvals, then confirmed failures, then unread results,
  newest first within each. First up, Next pending, Read pending and the
  Watch's alerts and results are all views of it; a project's number on the
  inbox is its share of it.
- **Read pending** — the phone's read-aloud and the Mac Inbox's explicit
  read-aloud entry: the pending queue spoken in
  order (stuck and waiting first, then unread results), ten at most, each
  item bound to its round and re-checked before it is spoken; pause, skip,
  replay, stop. The voice companion's provider speaks when it has a key,
  otherwise the system voice on iPhone. Mac uses its configured read-aloud
  provider and shares its ten-item queue with automatic Announcement; the
  Voice and reading panel exposes both. Nothing it does marks a result read; a live
  voice call pauses it, and manual reading requires explicit resume afterward.
  Background, automatic reading remains the Mac's
  **Announcement**.
- **Voice page** — the sheet behind the mic: the read-aloud queue, the
  conversation, and pause / mic / skip. It says which side the microphone is
  on (half duplex, ADR-0004). Closing it stops nothing. Its two extra voice
  tools, *mark read* and *instruct*, confirm a displayed round as read or
  send free text to a running or finished session; both report the
  application's receipt, never the agent's completion.

## Autonomous task desk (2026-09-13)

- **Permission mode** — what the agent explicitly reports about how it runs.
  Auto, bypass, accept-edits, plan, default and unknown remain distinct. Approval
  policy and sandbox describe different facts. A real wait needs attention in
  any mode, and unknown does not mean autonomous.
- **Unread result / read / mark unread** — a particular round's reading state.
  Read means that its result was presented to an active reader or explicitly
  confirmed. Automatic confirmation on macOS 15+ and iOS 18+ requires the result
  body to enter the viewport while its task is viewed in the foreground; older
  OS versions retain explicit read buttons. Loading offscreen text is not reading. It says nothing about review, validation or acceptance. Mark unread
  restores the browsing marker without renewing notifications or reminders.
- **Next pending task** — the next task needing a decision, followed by unread
  results. Reading and acting are separate from jumping to an agent's application.
- **Announcement** — an opt-in spoken account of a round's result or a real
  blocker, with task identity and source limitations. Hearing, skipping and
  replaying do not mark the result read. The queue holds at most ten items,
  including current playback. It does not open the microphone.
- **Activity ledger** — bounded, partial observations of tool intent and outcomes.
  Unconfirmed means no matching result was observed. Cumulative edit volume is
  distinct from the current net workspace diff.
- **Workspace changes** — read-only Git differences in an explicit uncommitted,
  staged or branch range. They describe the workspace, not one task's exclusive
  authorship; missing paths and repositories remain explicit limitations.
  Uncommitted compares the tracked working tree with HEAD, including staged
  changes; staged compares the index with HEAD; branch uses the selected
  baseline’s merge base.
