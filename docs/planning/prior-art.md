# vibebuddy — Prior Art & What to Borrow

**Last Updated**: 2026-09-05
**Method**: every GitHub project below was verified live with `gh` (existence, stars, license, last push). App Store apps are closed-source and were not code-verifiable. Claims I could not verify are marked as such — per the project rule to separate verified facts from candidates.

## 2026-09-05 remote-approval and mobile-companion survey

Question: with the phone-approval path now on `PermissionRequest` for Claude
Code and the Codex CLI, what do the mature remote/mobile projects do that
VibeBuddy does not? Sixteen projects and the two first-party features were
checked live (`gh api`, vendor docs) on 2026-09-05.

**First-party moved the goalposts.** Claude Code Remote Control (`/rc`,
all paid plans, cloud relay to claude.ai/code and the Claude iOS/Android app)
forwards permission prompts and `AskUserQuestion`, accepts prompts, images and
files from the phone, shows a git diff pane, and sends mobile push when a turn
finishes or a decision is needed — but only for Claude Code, only through
Anthropic's relay, not on API-key or gateway logins, and one remote session per
interactive process. Codex in the ChatGPT mobile app (2026-05-14, all plans)
reviews threads, approves commands and starts tasks against Codex Desktop and
CLI hosts through OpenAI's relay — the one surface that can act on a Desktop
thread, which no third-party monitor can (see the 2026-09-03 survey).

| Project | Ingress | Transport | Approve | Prompt/steer | Push (closed app) | Agents | Notes |
|---|---|---|---|---|---|---|---|
| [Happy](https://github.com/slopus/happy) (23k, MIT) | wrapper: `happy claude` / `happy codex` | hosted E2EE relay (Signal-style keys) | yes | yes, voice too | yes | Claude, Codex | iOS/Android/web/macOS; wrapper restarts the session in remote mode |
| [HAPI](https://github.com/tiann/hapi) (5k, AGPL) | wrapper (`hapi` runner) | self-hosted hub; WireGuard+TLS relay or Tailscale | yes | yes, terminal, voice | web push | 10 agents incl. Grok Build, Kimi, Antigravity | local-first answer to Happy; native iOS/Android in progress |
| [happier](https://github.com/happier-dev/happier) (1.6k) | wrapper | E2EE | yes | yes | yes | Codex, Claude, OpenCode, Kimi, Qwen | Happy fork |
| [Claude-Code-Remote](https://github.com/JessyTsui/Claude-Code-Remote) (1.3k, MIT) | hooks | email / Discord / Telegram | reply-based | yes | via messenger | Claude | no app |
| [vibe-notch](https://github.com/farouqaldori/vibe-notch) (2.5k, Apache) | own hooks over a Unix socket | local | notch UI | no | no | Claude | chat history in the notch; Mixpanel analytics |
| [c9watch](https://github.com/minchenlee/c9watch) (128, MIT) | OS process scan, no hooks | local | yes | no | no | Claude, Codex, Cursor | JSON CLI for agents to query each other |
| [ccnotifs](https://github.com/polyphilz/ccnotifs) | hooks | local | from the macOS notification | no | no | Claude | tmux-aware |
| [Armorer Gauntlet](https://github.com/ArmorerLabs/Armorer-Gauntlet) (11, Apache) | daemon + provider adapter | self-hosted E2EE relay, QR one-time tokens | yes | yes | Web Push | Codex (adapter model) | the closest architecture to ours, plus a chat composer |
| [OpenACP](https://github.com/Cosmos-Sapiens/openacp-telegram-adapter) (reviewed: the Telegram / Signal / Mattermost / WhatsApp adapter repos under Cosmos-Sapiens); [OpenClaw](https://github.com/openclaw/openclaw) is a separate project, listed here only as the same messenger-first pattern | bridge | Telegram/Discord/Slack/WhatsApp/Signal | inline buttons | yes | via messenger | Claude, others | messenger-first |
| [cc-safe-setup](https://github.com/yurukusa/cc-safe-setup), [claude-smart-approval](https://github.com/froggeric/claude-smart-approval) | PreToolUse / PermissionRequest hooks | local | auto-decide | — | — | Claude | rule packs and an LLM tier that decides unknown commands |

**Where VibeBuddy is ahead.** Zero-wrapper ingress (official hooks plus the
Codex rollout tailer, so sessions started from any terminal, IDE or Desktop
appear); one dashboard across seven agent adapters; no relay, no account, no
analytics; a Watch companion, Live Activity and a Mac notch glance, which none
of the above have; a voice companion that acts through function calling;
per-agent observation health (`degraded` / `unknownVersion`) and a
notification-delivery log, which only CodeStatus and MioIsland approach; the
always-allow store (ADR 0010) so an approval can persist a rule.

**Gaps, in priority order.**

1. **Closed-app push is unproven.** Every mobile competitor and both
   first-party features push when the agent needs you. The APNs code path and
   key exist (`docs/apns-setup.md`; the daemon reports `apns: on`), but device
   acceptance was never finished, so the phone only learns of a wait while the
   app is open or the WebSocket is alive. This is the single most valuable
   thing to close.
2. **No phone-side conversation view or composer.** Happy, HAPI, Armorer
   Gauntlet and Remote Control all show the transcript and accept a new prompt
   from the phone. VibeBuddy shows a summary/last-output peek, and `/answer`
   only reaches tmux panes. A read-only transcript tail (from the JSONL we
   already parse) would cover most "what is it doing?" moments; a composer is
   a larger, wrapper-or-injection decision.
3. **LAN only.** Off-network use depends on the user putting a Tailscale
   address in the QR; it is documented but not exercised. HAPI's split —
   self-host (Tailscale/Cloudflare) or an opaque WireGuard relay — is the
   pattern if remote ever matters; the cloud-relay products already cover the
   "on the train" case for Claude and Codex.
4. **Codex Desktop approvals stay invisible**, by platform limitation (no
   hooks, prompts not in the rollout). The ChatGPT mobile app is the answer
   for that surface; document the hand-off rather than re-attempt it.
5. **No smart auto-decide.** cc-safe-setup / claude-smart-approval decide
   unknown Bash commands with rule packs or an LLM before a human is asked.
   Our matcher asks whenever no rule matches; a curated safe-command list
   (read-only git/ls/grep families) on the daemon side would cut cards
   without ceding safety.
6. **Hook-less discovery.** c9watch finds sessions by process scan, so a
   machine whose hooks were never installed still shows something. We surface
   the gap as observation health with a repair path; a process-scan
   *discovery* (not state) signal would turn "no sessions reporting" into
   "3 Claude processes, hooks missing".
7. **Platform reach.** Mac + iOS only; Happy/HAPI cover Android, Windows and
   Linux hosts. Out of scope for a personal tool, noted for completeness.

Not adopted: wrapper-based ingress (it changes how every session is launched
and loses sessions started elsewhere), messenger bridges (a second inbox for
the same decisions), and analytics of any kind.

## 2026-09-03 Codex Desktop survey

Question: can VibeBuddy monitor Codex Desktop sessions, and what do mature
projects do differently? Twelve projects were inspected at default-branch HEAD
with `gh`, together with the openai/codex `main` sources and this Mac's own
`~/.codex` (no transcript content read).

**Ground truth (openai/codex, verified locally).** Codex Desktop is now the
Codex Framework inside `ChatGPT.app`; it spawns `codex app-server` over stdio
with no `--listen`, so no other process can attach to its live threads
(`app-server-control.sock` belongs to the CLI daemon, `ipc/ipc.sock` is an
IDE-context router). openai/codex issue #25914 documents that a second
app-server sees Desktop threads only as `notLoaded`. Rollouts persist only
`task_started`, `task_complete`, `turn_aborted`, `item_completed`,
`token_count`, `thread_settings_applied` and a few `*End` records
(`codex-rs/rollout/src/policy.rs`); approval and `request_user_input` prompts
are explicitly not persisted. Desktop rollouts carry
`originator: "Codex Desktop"` with `source: "vscode"` (the enum default), and
subagent threads reuse the same originator with `thread_source: "subagent"`.
The core `threads` table lives in `~/.codex/state_5.sqlite`;
`~/.codex/sqlite/codex-dev.db` is the Electron app's private catalog.

| Project | Desktop support | Signal | States | Model / tokens | Remote actions |
|---|---|---|---|---|---|
| [CodexBar](https://github.com/steipete/CodexBar) (20k+) | label only, via originator + ChatGPT app-server process | process table + today/yesterday rollouts + `state_5.sqlite` | active/idle (120 s mtime) | model from sqlite, cost from `token_count` | none |
| [Agent Signal Bar](https://github.com/guan-ops/Agent-Signal-Bar) | yes, hook-free desktop monitor | recursive rollout tail with ctime/offset cursors | thinking/working/tool_done/done/permission/attention | `token_count`, tool from `function_call` | none |
| [open-vibe-island](https://github.com/Octane0411/open-vibe-island) (2k) | partial | incremental rollout fold + own app-server (own threads only) + `archived_sessions/` | running/approval/question/completed | usage module | none |
| [agentsview](https://github.com/kenn-io/agentsview) (5k+) | ingests, no discrimination | FSEvents + byte cursors + `history.jsonl` hot list | awaiting_user / tool_call_pending + recency | `turn_context.model`, `last_token_usage` | `codex resume` in a terminal |
| [notchi](https://github.com/sk-ruban/notchi) (1k) | no (hook ingress) | hooks, then rollout `DispatchSource`, `state_*.sqlite` | hook-driven | `turn_context` + `token_count` | none |
| [codestatus](https://github.com/henriquegpb/codestatus) | no, by design | hooks only | working/free/approval/answer | none | none |
| [parallex](https://github.com/Jiply/parallex) | yes | `lsof` on open rollouts + backward tail scan | active/inactive | — | none |
| [pocket-codex](https://github.com/acking-you/pocket-codex) | observe + destructive takeover | own app-server + rollout tail + `lsof` | owned/resumable 2×2 | `tokenUsage / modelContextWindow` | own threads only |
| MioIsland, CodexLens, ccpocket | none / label only | — | — | — | own threads only |

**Consensus.** Every project observes Desktop through the rollout JSONL and
none can act on a Desktop thread; approval waits are inferred (pending tool
call plus a quiet file) and admitted to be heuristic; liveness needs a second
signal beyond mtime (`lsof`, the ChatGPT app-server process, or the
`archived_sessions/` move); `token_count` is bookkeeping, never activity.

**Where VibeBuddy stood.** `CodexRolloutMonitor` already had the strongest
turn model in the sample (concurrent `turn_id`s, event-driven watchers,
bootstrap of only active turns, collaboration topology). Four gaps were real:
discovery only looked at today's and yesterday's date directories although
resumed threads append under their start date (10 such files in the last week
on this Mac); Desktop rows had no model, context or spend; subagent rollouts
surfaced as extra top-level sessions; an archived rollout was untracked
silently.

**Adopted on 2026-09-03.** Recursive discovery bounded by the recency window;
`turn_context` / `thread_settings_applied` → model, `token_count` → context
and spend through the reducer's enrichment path, gated so an idle thread's
bookkeeping never creates a row; `thread_source`/`source.subagent` filter;
`sessionEnd` when a surfaced rollout vanishes. Not adopted: `lsof` liveness
(process-table cost for a signal the 2 h stale reconcile already
approximates), approval inference from a quiet file (false "needs you" is
worse than none), and any app-server attachment (impossible on macOS without
patching ChatGPT.app).

## 2026-09-02 activity-monitoring refresh

The current mature implementations converge on a **hybrid event model**, not
CPU sampling:

| Project | Current signal model | What we adopt |
|---|---|---|
| [CodeStatus](https://github.com/henriquegpb/codestatus) | Official Claude/Codex lifecycle hooks; process observation is used for discovery and exit reconciliation, not to guess whether a turn is busy. | Semantic hook states, an explicit confidence/unknown path, and visible unreported-state guidance. |
| [Agent Signal Bar](https://github.com/guan-ops/Agent-Signal-Bar) | Claude hooks; known Codex local session logs across Desktop/CLI/IDE, with optional hooks for permission and lower latency. | Codex JSONL as the Desktop-safe baseline, plus hooks where the host actually executes them. |
| [CodexLens](https://github.com/Yukhy/codexlens) | Correlates Codex and Claude JSONL with local process labels, working directory, thread ID, and time. | Preserve source identity and correlate by stable IDs; never infer a run from a project name alone. |
| [AgentRadar](https://github.com/ahmedmigo/AgentRadar) | Process discovery plus Claude transcript parsing. | Process presence is useful for liveness, but is too coarse to drive working/waiting by itself. |

The resulting VibeBuddy contract is:

1. **Claude Code** — lifecycle hooks are authoritative. `SessionStart` means the
   session is available/idle; only `UserPromptSubmit` or tool activity means
   working. Permission, elicitation, and question events mean needs-response.
2. **Codex CLI** — lifecycle hooks provide the same semantic transitions. The
   currently released 0.152.1 binary was also exercised locally: it skips
   commands carrying `async: true`, so VibeBuddy keeps its commands synchronous,
   capped at three seconds, with a one-second local HTTP forwarder cap.
3. **Codex Desktop/IDE** — tail `~/.codex/sessions/**/rollout-*.jsonl`, because
   these surfaces do not reliably execute the user's CLI hooks. Track concurrent
   turn IDs so one completed turn cannot mark another active turn done; clear
   tools on both function and custom-tool outputs; treat `request_user_input` as
   needs-response; accept `final_answer` as a completion fallback.
4. **Overview UI** — default to all sessions and always show agent source,
   normalized current activity, and recency. An empty collector is shown as
   “No sessions reporting” with a hook-repair path, not as an ambiguous blank.

### Current maturity benchmark

Repository popularity is not treated as correctness, but it is useful for
separating maintained ecosystems from one-off demos. The following projects
were re-fetched on 2026-09-02 and inspected at their default-branch HEAD:

| Project | Why it matters to VibeBuddy | Pattern to follow |
|---|---|---|
| [CodexBar](https://github.com/steipete/CodexBar) (20k+ stars) | The largest maintained macOS Codex/Claude companion in this sample; strongest usage/provider reliability work. | Provider boundaries, adaptive refresh, explicit watchdog/timeout behaviour. |
| [AgentsView](https://github.com/kenn-io/agentsview) (5k+ stars) | Mature local-first parser/index for Claude, Codex, and many other agents. | Per-provider parsers, incremental cursors, durable local indexing, parent/child lineage tests. |
| [Notchi](https://github.com/sk-ruban/notchi) (1k+ stars) | Direct Claude + Codex macOS progress UI, including Codex transcript and process reconciliation. | Per-session file-system watchers, short debounce, slower liveness reconciliation, compaction-aware refresh. |
| [MioIsland](https://github.com/MioMioOS/MioIsland) (500+ stars) | Rich Claude attention/permission UI with subagent parsing and remote delivery. | Explicit subagent state, stable event deduplication, and visible notification-delivery failures. |
| [Claude View](https://github.com/tombelieber/claude-view) | Smaller audience but unusually clean live-state boundary: hook fields and JSONL fields feed one classifier. | Keep raw-source parsing separate from classification and preserve source identity. |
| [Claude Code Hooks Multi-Agent Observability](https://github.com/disler/claude-code-hooks-multi-agent-observability) (1k+ stars) | Focused reference for hook-event timelines across agents. | Persist a bounded event timeline for diagnosis instead of exposing only the latest state. |

This comparison also puts the role of the two very popular usage tools in
context: [ccusage](https://github.com/ccusage/ccusage) and
[Claude Code Usage Monitor](https://github.com/Maciek-roboblog/Claude-Code-Usage-Monitor)
are mature sources for token/quota accounting, but they are not authoritative
progress-state engines. They complement lifecycle hooks rather than replace
them.

### Changes adopted in this refresh

- Claude `PostModelSwitch` is now ingested, so `/model`, automatic fallback,
  plan-mode model changes, and resumed model settings update the live card.
- Claude `CwdChanged.new_cwd` is now ingested, so a mid-session `cd` updates the
  displayed project without changing working/waiting/done state.
- These are metadata-only reducer events: they preserve the active tool,
  attention state, and `statusSince`, matching the explicit-state approach in
  Notchi, MioIsland, and Claude View.
- `chronicle` remains disabled. None of the mature progress monitors above
  needs it; official hooks plus local rollout/transcript records are the stable
  signal path.

### Remaining improvements, in priority order

1. **P1 — event-driven Codex Desktop tailing.** Replace the steady one-second
   file scan with `DispatchSourceFileSystemObject` watchers per active rollout,
   a short coalescing debounce, and a slow discovery/liveness fallback. This is
   the clearest low-power improvement from Notchi.
2. **P1 — source health and confidence.** Record whether each field came from a
   hook, rollout, transcript, or process reconciliation; show last event time
   and a repair reason when a source is stale. CodeStatus and Claude View make
   unknown/degraded state explicit instead of silently guessing.
3. **P1 — subagent topology.** Preserve parent session, child/teammate ID,
   running count, and last child tool instead of flattening `SubagentStart` and
   `TaskCreated` into an ordinary tool label. AgentsView and MioIsland both test
   lineage explicitly.
4. **P2 — bounded event journal.** Store normalized lifecycle transitions in a
   small rotating SQLite journal for diagnostics, replay after daemon restart,
   and notification delivery receipts. Do not index full unpublished prompts or
   tool output by default.
5. **P2 — notification delivery health.** Surface APNs/local-notification
   permission or delivery failure with per-reason debounce, rather than treating
   “sent” as “received.” MioIsland's failure notifier is the useful pattern.
6. **P3 — usage/quota adapter.** Add an optional, separately refreshed usage
   provider modeled after CodexBar/ccusage. Keep quota refresh out of the
   progress reducer so network/credential errors cannot corrupt session state.

## License caveat (read first)

Some older references below have **`no-license` on GitHub = "all rights
reserved."** We only borrow observable architecture and concepts and write our
own Swift. The 2026-09 references have mixed licenses; no implementation code was
copied from any of them.

## Verified open-source references

| Project | Verified | Borrow | License |
|---|---|---|---|
| **onikan27/claude-code-monitor** | ✅ ⭐235, active 2026-01 | The whole shape: hook-into-`settings.json` + WebSocket + **QR pairing** + 3-state model. Closest prior art. | no-license (study only) |
| **Maciek-roboblog/Claude-Code-Usage-Monitor** | ✅ ⭐8.1k | Context-window % and quota/limit **prediction & warnings** (a v1.5 feature on top of our `tokens`). | no-license (study only) |
| **gao-sun/eul** | ✅ ⭐9.9k, stale since 2024 | How to structure a **SwiftUI macOS monitoring app** (metrics collection, refresh, status UI). | no-license (study only) |
| op7418/m5-paper-buddy | ✅ (planning ref) | Transcript-tail JSONL parsing; RUNNING/WAITING sets; fail-open hook curl. | — |
| Octane0411/open-vibe-island | ✅ (planning ref) | Source-agnostic `SessionState` reducer across 10+ agents; macOS menubar/notch UX. | GPL-3.0 (study; copyleft) |

## Closest analog deep-dive: onikan27/claude-code-monitor (verified)

Node/TypeScript, serverless, no external data transmission. Confirmed details:

- **Collection**: registers hooks into `~/.claude/settings.json`; file-based state, no API server. (Same approach we chose.)
- **Transport**: **WebSocket** for real-time updates; default port 3456 with auto-fallback. (Same as ours.)
- **States per session**: **● Running / ◐ Waiting / ✓ Done** — essentially our `working / needsResponse / done`. Independent confirmation our 3-bucket model is right.
- **QR pairing + token**: press `h` → shows a QR encoding the URL **with an embedded auth token** ("treat it like a password"). Phone scans → connected. No manual IP typing.
- **Remote**: responds to permission prompts via an on-screen **D-pad + Enter + screen capture** of the terminal. (This is the v2 territory we deferred — and a hint that our *structured* hook-based approval would be cleaner than screen-scraping.)
- **Tailscale**: a `-t` flag makes the QR encode the Tailscale `100.x` IP (WireGuard-encrypted). Confirms our "transport is config, not code" decision — Tailscale is just a different value in the same QR.

## Could-not-verify / closed-source (do not treat as fact)

- **AgentsRoom**, **Control: AI Agent Remote** — described as App Store apps (closed source). Useful only as **UX inspiration** (color-coded Thinking/Coding/Done/Blocked; LAN-only; streaming diffs). No code to borrow.
- **agtrace**, **RepoBar**, **KyanBar**, **"Peek"** — `gh` search returned **no matching repo** under these names. Unverified; not relied upon. (Generic menubar/dashboard ideas are well covered by `eul` and `open-vibe-island` anyway.)

## Borrow-map → impact on our plan

**1. Strong validation (no change needed):**
- 3-state model (Running/Waiting/Done) is independently the industry pattern. ✅
- Hook-into-`settings.json` + WebSocket + local-first is the converged design. ✅
- "Transport = config" (LAN IP today, Tailscale `100.x` later via the same channel). ✅

**2. Two concrete refinements worth adopting (decisions for the user):**
- **R1 — Mac side as a SwiftUI `MenuBarExtra` app** (not a headless CLI). Gives a Mac-side glance, a natural home for pairing/launch-at-login/port config, and matches `eul` / `open-vibe-island`. Still all-Swift, still embeds the hook-intake + reducer + WebSocket server.
- **R2 — QR-code pairing with an embedded token** as the connect UX. The Mac menubar shows a QR encoding `host:port` (+ a bearer token); the phone scans it instead of typing an IP. Near-free, removes manual config, and the token gives light LAN auth — softening the earlier "no auth in v1" to "trivial auth in v1." Same QR later encodes the Tailscale IP.

**3. Deferred features these projects confirm are worth a later look:**
- Context-window % + quota/limit prediction (from Claude-Code-Usage-Monitor) → v1.5 on top of `tokens`.
- Structured remote approval (cleaner than onikan27's screen-capture+D-pad) → v2.
