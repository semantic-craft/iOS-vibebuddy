# Cursor hooks

Verify the existing Cursor hook adapter reports shell failures correctly and keeps stop/follow-up work inside Cursor's hook deadline. This recipe does not establish a persistent IDE turn history.

## Sub-features

- Shell result envelopes with a nonzero exit status become failed tool results.
- JSON text read from an ordinary file remains file content rather than a tool error.
- The stop script reports status before collecting a queued follow-up and discards failed or partial HTTP responses.
- Hook installation preserves other hooks and is repeatable.

## How to get to it (user POV)

In an independently identified Cursor IDE profile using a disposable project and the isolated daemon, run a harmless shell command that exits with status 1. Inspect its failed result in VibeBuddy. Queue a follow-up and observe whether the actual next agent turn starts. A queue being collected does not by itself prove execution.

## Driving it with control-vibebuddy

1. Launch and doctor-check the isolated daemon under the feature index rules. Use a temporary Cursor configuration/profile; never rewrite production global hooks for verification. Confirm the IDE window/profile identity before interacting with it.
2. Run `python3 hooks/test_install_agent_hooks.py`. Its real hung and partial-response HTTP checks must exit normally with empty output inside the configured stop-hook timeout; installation checks use disposable directories.
3. Run the affected `CursorHookAdapter` Swift suite. Fixture results verify decoding and ledger behavior, not actual IDE emission.
4. Through the real isolated IDE, exercise a failed shell command and a successful read of a file containing JSON error-like fields. Save the emitted hooks and a fresh authenticated snapshot. Check the original tool identity and result, preserving the difference between shell metadata and file contents.
5. Observe a real stop/follow-up cycle and record elapsed time, collection and the actual subsequent turn separately. Do not infer immediate steering or delivery from a successful HTTP collection response.
6. Capture evidence, close only the profile/processes owned by this run, and clean the isolated daemon with the helper. If the IDE cannot be independently targeted, report that concrete gap and retain the automated checks as separate evidence.

## Gotchas

- Current stop networking budgets are 1 second for observation and 2 seconds for collection, within the installer’s 5-second hook timeout. Failed collection must produce no follow-up payload.
- Local user hooks do not automatically observe remote Cloud execution. Cloud project hooks are a separate supported provider surface and require their own transport.
- No new turn store or precise user-turn grouping is implied by these fixes. Provider generation IDs must not be guessed to mean user-turn IDs.
