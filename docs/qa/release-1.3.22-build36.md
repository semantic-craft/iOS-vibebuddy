# macOS 1.3.22 build 36

## Scope

Build 36 combines the completion recovery and settings work from build 35 with responsive Agent CLI detection, incremental history indexing, responsive history search, Codex fork identity repair, and managed Cursor recovery and native controls. The iOS changes are included in source control but are not an iOS release.

## Existing behavior evidence

- Candidate `ac96da2c`: isolated native Mac acceptance covered distinct parent/fork conversations, search while indexing, appended messages, repeated Agent CLIs navigation, and same-named project selection. The checkout was clean and the recorded source hashes remained unchanged. This was a Debug run, not final Release installation evidence.
- Codex fork repair `004dbb8a`: 29 XCTest and 78 Swift tests, distinct parent/child HTTP reads and pagination, and independent review passed. The existing 2 MiB completion-record limitation remains.
- Cursor work was exercised separately in its worktree: full plan, refusal, restart and same-session continuation, real Read tool output, explicit read acknowledgment, stop, and rejection of stale actions. Integration checks for the final source revision are recorded below.
- The earlier installed build 35 exercised real Desktop completion recovery and saved-key summary generation. Its separate record is retained in `release-1.3.22.md` and is not evidence of a build 36 installation.

## Retained limits

- Cursor's upstream `WritableIterable is closed` error can arrive as ordinary assistant text followed by `end_turn`. The original text is visible; reliable structured failure classification is unavailable. No automatic retry or text-matching failure heuristic was added.
- Automatic read acknowledgment under genuine user-presence conditions and live Cursor IDE Hooks were not accepted. Managed ACP acceptance does not establish IDE integration acceptance.
- Physical iPhone/Watch, production APNs and iOS 17 acceptance remain separate. The last iOS pairing run contains a failed final step. The iOS submission condition has not been met.
- Existing denied macOS notification permission and software playback completion do not establish banner delivery or human listening acceptance.

## Final release checks

Pending final source integration, focused checks, Release build, Developer ID verification, app and DMG notarization, and signed Sparkle feed publication. This section is updated from actual results before publication.
