# Codex read-only views: acceptance (2026-10-01)

Scope: tickets 04 / 05 / 06. The Mac Session reader uses newest-first official
item pages, with an explicit earlier-page action and local-source fallback.
Activity shows the selected thread's goal and background terminals. No new
control action is exposed.

## Evidence

- `swift test --package-path VibeBuddyMac -j 4 --filter CodexTaskReadsTests`:
  4 tests pass. Protocol-boundary tests verify exact thread IDs/cursors, descending
  requests, chronological output, overlap deduplication, refresh retention of previously loaded pages, malformed responses,
  nil goals, unavailable connection, and absence of resume/start/goal writes or
  process termination calls from the read views.
- Mac app Debug build passed with Xcode, signing disabled.
- A separate Codex 0.159.2 app-server ran under disposable HOME/CODEX_HOME and
  a private Unix socket. A new disposable thread and goal were set up by the
  acceptance harness (not by the app's read path). All three official read
  methods returned their expected response shapes. No production daemon used.
- Isolated app `com.vibebuddy.e2e.octoberreads`, port 18817: Computer Use opened
  the disposable thread, confirmed `Codex history · read` and empty history,
  then Activity displayed the actual objective, goal status, tokens used,
  token budget, elapsed time and the empty background-terminal state.
- The disposable Codex home had no model login. Its goal became blocked after
  a model attempt; the UI correctly displayed that returned status rather than
  inventing progress. This setup validates reads, not autonomous model execution.

## Limits

Real Codex returned an empty item page and no running background terminals.
A local protocol fixture was then served on the same disposable socket. Computer
Use verified 65 messages: initial page 36–65, earlier page 6–65, final page 1–65
with the history-start label and no further pagination action. Request log cursors
were nil, 30, 60. Activity displayed a fixture command/PID/CPU/memory row.
No control-write methods were issued by those read actions. This is boundary
fixture UI evidence, not a live long conversation or live process metrics. No production installation or phone UI change occurred.

After stopping the disposable server, Activity showed `Codex service is not
connected` for both reads, rather than an empty goal or terminal list. The
isolated GUI and its server were terminated by their own recorded process only.
