# Project standards

Read the sections required by [AGENTS.md](AGENTS.md) for the current task.

## Verification

Personal-use project. For app or daemon behavior changes, accept end to end: build and run the affected app or daemon, exercise the affected flow with real Claude Code or Codex data within the authorized scope, and check the snapshot, UI, notification, recovery, or installation behavior the change touches. Check only affected behaviors.

Run without asking: `swift build` / `swift test` in this checkout, XcodeGen and simulator builds, and an isolated `vibebuddyd` on a non-9876 port with a disposable HOME (`verify-vibebuddy` owns that recipe). Never launch a second production menu-bar instance.

If real-device or installed-app acceptance needs an unavailable device or an effect outside the task scope, finish the implementation and the available checks, then report that specific gap; the other checks do not prove it.

Keep a small number of fast tests for critical pure logic or a reproduced regression. No coverage targets, test-first mandates, or per-edge-case matrices; do not let test expansion displace end-to-end validation. Which tests earn their place (keep/delete rubric, sources): `docs/agents/testing-policy-research.md`.
