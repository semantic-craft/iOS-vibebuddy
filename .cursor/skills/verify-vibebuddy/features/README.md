# VibeBuddy verification map

This directory is the maintained source for verifying user-facing VibeBuddy behavior. Read this index before driving, then use the matching feature file as the recipe.

## Baseline preconditions

- Launch an isolated `vibebuddyd` with `.cursor/skills/verify-vibebuddy/helpers/control-vibebuddy launch` (add `--pair` only for pairing recipes).
- `VIBEBUDDY_QA_PORT` is set and is **not** `9876` (default `18765`).
- Disposable `HOME` is the run state dir, not the login home. Production `~/Library/Application Support/vibebuddy/token` is unused.
- `VERIFY_EVIDENCE_DIR` is outside the scratch state dir so cleanup cannot eat proof.
- `control-vibebuddy doctor` reports health `ok`, snapshot `401` without a token, snapshot `200` with the run token, and the recorded PID owning the isolated port.
- Never drive the installed menu-bar app, a simulator pointed at `:9876`, or an instance this run did not start.
- On Linux, or without Swift/Xcode, `launch` / `doctor` report `blocked` and the feature is `verified-unreachable` with that host gap — not verified via a fake harness.

## Driving conventions

- Start every recipe from a freshly launched isolated daemon unless the feature file says otherwise.
- Drive the hub through `control-vibebuddy` HTTP verbs (the same routes the iPhone and hooks use). Drive iPhone Demo through `control-vibebuddy sim-demo` plus the labeled buttons.
- Treat every command as literal. Keep session ids, project paths, and decision strings unchanged.
- After a mutation, re-read `/snapshot` (or the Demo UI) from a second call. Do not trust the write response alone.
- Restore nothing on the user's Mac. Cleanup stops this run's PID only. Keep proof artifacts.

## Proof and skip reporting

- Capture the user action and the resulting snapshot or UI, not only the final screen.
- HTTP proof includes the command, status code, and a saved `snapshot.json` under `$VERIFY_EVIDENCE_DIR/<feature-id>/`.
- UI proof includes a screenshot with VibeBuddy identity visible (`Demo` title or a seeded project name).
- Record the feature id and entry point on every artifact (`evidence --label <id>` writes `meta.txt`).
- An unreachable path is reported with the attempted command and the unmet precondition (macOS, Swift, simulator, pairing window, real agent).
- Do not report a skipped entry point as verified through a different path. Demo is not live pairing. A hook-seeded snapshot is not a real Claude Code session.

## Feature entry contract

Each feature file starts with an H1 and one paragraph. It then uses exactly these four H2 sections in order: `Sub-features`, `How to get to it (user POV)`, `Driving it with control-vibebuddy`, `Gotchas`.

## Features

- [Dashboard sessions](./dashboard-sessions.md) covers the three session states the dashboard and menu feed show.
- [Phone pairing](./phone-pairing.md) covers the two-minute pairing window and device registration.
- [Remote approval](./remote-approval.md) covers Approve / Deny on a held permission.
- [Question reply](./question-reply.md) covers answering a waiting question.
- [iPhone Demo](./iphone-demo.md) covers exploring the iPhone chrome without a Mac.
