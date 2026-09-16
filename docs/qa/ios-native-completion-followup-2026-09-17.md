# iOS companion completion update

The phone needs an accompanying update because its local completion title and offline speech fallback run inside the iOS app. The Mac update alone cannot change those paths.

## Behavior

- Local and remote completion notification titles use the conversation's display title.
- Mac and iOS recheck the current notice state and presentation revision before delivering a queued completion notification. Pending and cancelled notices are ineligible.
- Offline iOS completion speech requires the current source and round's validated saved summary. It cannot use generic session progress as a completion summary. Prepared offline speech becomes invalid if the same notice is subsequently cancelled.
- Server-verified result excerpts remain available when summary generation is unavailable.
- A pending notice recovered after restart is cancelled. A ledger write failure cannot turn invalid native completion evidence into a plain completion notification.
- Native settlement remains the completion boundary. This update does not reduce reminder frequency or add wire fields.

## Existing worktree audit

All 21 uncommitted changes across the two development machines were compared against their original bases and current main. Useful changes were already incorporated. Four overlapping files retained newer main behavior: native completion settlement, premature hook protection, the phone reader extraction, and checkout-specific path copying. Original working trees were preserved.

## Verification

Earlier build 40 evidence is documented separately in `cross-host-summary-integration-2026-09-17.md` and is not proof of build 41.

- Mac focused regression: 15 cases, with three reproduced failures before the fix and 15 passes afterward.
- Shared completion and reading logic: 12 cases passed.
- Final iOS Simulator run: 22 focused cases and one real-network integration case passed, with no failures or skips.
- Two fresh real Codex tasks ran through an isolated native app-server and daemon. iOS consumed the completed second task through its real HTTP and WebSocket clients, read its exact-round result, prepared current speech, and preserved the unread state. All 16 acceptance checks passed, including temporary credential and process cleanup. The phone connected after completion; this run does not establish a visible spinner transition.
- The temporary native integration harness and its disposable configuration are excluded from the committed test suite.

## Boundaries

No wire migration or credential change is required. Native iOS UI, physical-device notification delivery, and audible speech are separate from simulator runtime tests. The secondary host's Claude Code authentication failure remains a separate acceptance gap. No Store or TestFlight release is part of this change.
