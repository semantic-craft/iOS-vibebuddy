# vibebuddy — Prior Art & What to Borrow

**Last Updated**: 2026-09-02
**Method**: every GitHub project below was verified live with `gh` (existence, stars, license, last push). App Store apps are closed-source and were not code-verifiable. Claims I could not verify are marked as such — per the project rule to separate verified facts from candidates.

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
