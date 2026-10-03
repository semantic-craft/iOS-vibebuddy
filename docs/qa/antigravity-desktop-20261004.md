# Antigravity desktop observation — 2026-10-04

Implementation branch: `codex/antigravity-desktop`, based on the Antigravity integration branch and shared session registration APIs from `eacce64d`.

## Scope and evidence

The desktop adapter discovers only the current user's Antigravity / Antigravity IDE language-server executables using kernel process paths. It calls only `GetAllCascadeTrajectories` and `GetCascadeTrajectorySteps` on discovered loopback HTTPS ports. Responses, subprocess output, connection time and each polling pass are bounded; redirects, proxies, cookie storage and credential storage are disabled. The self-signed TLS exception is restricted to the selected loopback host and port. CSRF values remain in memory and are never logged.

Actual Swift client acceptance read the existing synthetic cancelled conversation. The native list reported IDLE; the last step reported CANCELED. It did not resume, edit or cancel a conversation. The earlier Python-only result was not used as a substitute for the Swift transport: the initial Swift attempt failed certificate validation, and explicitly supplying the task authentication delegate to `URLSession.bytes` fixed that discrepancy.

Durable evidence: `~/Projects/_shared-work/iOS-vibebuddy/antigravity-desktop-20261004/`.

- `native-rpc/results.json`: initial real-client failure.
- `native-rpc-taskdelegate/results.json`: successful real TLS/RPC read after the fix.
- `tool-cancel-red/results.json`: reproduced incorrect terminal classification of a cancelled tool while the session remains RUNNING.
- `scoped-pass/results.json`: three checks passed, including the real read-only RPC check.
- `integrated-pass/results.json`: all three tests passed, but the runner flagged a source fingerprint change while this QA note was edited.
- `final-pass/results.json`: authoritative post-commit repetition after merging the shared quota/source integration and quiet cross-turn reconciliation. Command: `tools/check.py mac --filter AntigravityDesktop`, with the opt-in synthetic cancelled-conversation ID supplied as `VIBEBUDDY_ANTIGRAVITY_CANCELLED_PROBE`.

The regression boundary checks WAITING precedence over RUNNING, cancellation clearing a question, individual tool cancellation remaining working, initial historical completion staying quiet, and cancelled endings carrying no successful result. Unchanged terminal summaries avoid repeat step reads. Active rows have priority and oldest-read-first scheduling, at most four requests per batch and an eight-second scheduling budget (an already-started batch may consume its five-second request deadline). Rows not covered by that budget explicitly carry observation uncertainty. A new already-terminal turn clears stale prior-turn state quietly; it cannot replay a historical completion. WAITING only requests user attention when a native interaction payload is present; ordinary tool errors do not become terminal execution failures.

## Remaining acceptance

This slice has not installed or launched the production app, bound port 9876, or exercised phone/Watch delivery. The integration owner must run the daemon-to-snapshot and three-client flows, native successful final body, genuine approval waits, disconnect/recovery, independent IDE coverage and release acceptance. RPC `plannerResponse.response` is the native final-text field; absent text stays unavailable and is not replaced with the summary. The implementation follows the source interface documented in the [context-window monitor](https://github.com/AGI-is-going-to-arrive/Antigravity-Context-Window-Monitor/blob/main/src/tracker.ts).
