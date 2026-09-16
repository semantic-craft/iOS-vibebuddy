# Completion announcements — 2026-09-17

## Behavior

- Codex final-answer text alone does not end a running turn. A hook Stop cannot close a turn still active in the native rollout.
- Claude Code speech waits for the matching final response and its settled Stop-hook summary. Nested-agent Stop events do not end the parent task.
- Cursor hook completion uses transcript bytes appended after the prompt and requires a successful native ending. A later prompt or handed-over follow-up prevents that completion from being spoken.
- Completion speech for every agent requires verified original result material. Missing evidence returns no completion presentation.
- Announcements use the conversation title. Codex resolves title changes by exact thread ID in its session index. A corroborating native source can update the name while App Server retains authority over progress.
- When summary generation fails after result verification, speech reads a labeled, bounded excerpt from the verified result. It no longer substitutes the “round ended, summary unavailable” message.

## Automated evidence

124 focused Swift tests passed in nine suites. Coverage includes early Codex final-answer/Stop events, title lookup and renames, Claude nested Stop and hook continuation, Cursor native termination and follow-up handoff, stale or conflicting results, and summary-provider failure. Opt-in read-only replay exercised actual local Claude Code, Codex and Cursor records.

An isolated daemon on port 18769 with a disposable HOME passed health, bearer-auth rejection, authenticated snapshot and source-isolation checks. Through the same `/presentation` HTTP route used by clients:

- Recorded Codex final-answer text and an injected early Stop kept the task working without a completion. Its recorded native terminal event ended it and returned named result content.
- A hook-only completion without original evidence returned HTTP 409.
- Real Claude final-response/Stop-summary records and Cursor final-response/turn-ended records were replayed with reconstructed hook delivery. Claude timestamps were shifted to the replay clock. Before their settled endings, speech returned 409; afterward, it returned 200 with the conversation name and a verified result excerpt.
- No summary provider was configured in the isolated daemon. These HTTP checks verify result fallback and eligibility, not live model generation or audible TTS. Test-provided names for Claude and Cursor verify propagation, not native title discovery.
- The daemon was stopped and its disposable data removed. Raw conversation text was not committed.

Reproduce focused tests on a machine containing eligible local recordings:

```sh
VIBEBUDDY_COMPLETION_REPLAY=1 swift test --package-path VibeBuddyMac --filter 'ContentPresentationTests|CompletionRecoveryTests|CursorTranscriptMonitorTests|HookParserTests|CodexRolloutMonitorTests|CompletionResultTests|CompletionResultReplayTests|CodexCompletionReaderTests|CompletionNoticeIntegrationTests'
```

## Acceptance boundary

Human listening and new live task acceptance remain with the owner. Unknown or insufficient native evidence suppresses completion speech; these checks do not establish that every agent/version exposes enough evidence to announce every completion.
