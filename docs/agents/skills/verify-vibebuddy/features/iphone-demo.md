# iPhone Demo

**See the demo (no Mac needed)** (or `VIBEBUDDY_DEMO=1`) shows the iPhone dashboard with sample sessions and no network, so the chrome is reviewable without pairing. Demo **Approve** / **Reply** only mutate that in-memory sample.

## Sub-features

- `demo-enter` opens Demo from the Connect screen or the launch env.
- `demo-approval` **Approve** / **Deny** on `demo-edit` (Edit diff) or `demo-build` (full Bash command) clears that sample wait.
- `demo-reply` **Reply** on a sample question moves that row to `working` with summary `Answered from phone: …`.
- `demo-identity` the navigation title is **Demo**, not a Mac name.
- `demo-not-live` Demo never calls `/snapshot` or `/decision` on a daemon.

## How to get to it (user POV)

- On iPhone Connect: tap **See the demo (no Mac needed)**.
- For simulator QA: launch `com.vibebuddy.app` with `VIBEBUDDY_DEMO=1` (and usually `VIBEBUDDY_SKIP_NOTIFICATIONS=1`), as `tools/watch-qa-shots.sh` / `tools/watch-relay-qa.sh` do.
- Watch Demo pages use `VIBEBUDDY_WATCH_PAGE` / `VIBEBUDDY_WATCH_SCENARIO` (separate Watch QA, not this file's default drive).

## Driving it with control-vibebuddy

Preconditions:

- macOS with a booted iOS Simulator and a Debug `VibeBuddyApp.app` (see helper error text for the `xcodegen` / `xcodebuild` command).
- You are not launching the App Store install or a device that already holds a production pairing you care about. Simulator env pairing is launch-only and not saved.
- Isolated `vibebuddyd` is **not** required. If a daemon is running for another feature, leave it alone; Demo must not be pointed at it.

- **Launch Demo.** Run `control-vibebuddy sim-demo`. The helper installs the Debug app if present and launches with `VIBEBUDDY_DEMO=1`.
- **Identity.** The iPhone UI title is **Demo**. Sample rows include `todo-app` (Edit sort-reminders, id `demo-edit`), `search-indexer` (Bash tests, id `demo-build`), and `ios-vibebuddy` (`demo-work`, working / followed).
- **Approve sample.** Open `todo-app` / `demo-edit`. Tap **Approve**. The Edit wait disappears and that row is `working`. **Deny** is the same visible clear (Demo does not distinguish allow vs deny in the sample store).
- **Reply sample.** On a question row, tap **Reply**, submit any non-empty text. The row summary starts with `Answered from phone:`.
- **Proof.** Screenshot the Demo dashboard with the **Demo** title and at least one sample project visible, plus a second shot after Approve on `demo-edit`. Save under `$VERIFY_EVIDENCE_DIR/iphone-demo/`. Run `control-vibebuddy evidence --label iphone-demo` for `meta.txt` (host / run id). On Linux or without simctl, `sim-demo` prints `blocked` — record `verified-unreachable` with that host gap. Do not substitute App Store marketing screenshots.

## Gotchas

- Demo is **not** pairing, APNs, Live Activity recovery, or a real agent. A Demo screenshot never verifies those features.
- `VIBEBUDDY_HOST` / `PORT` / `TOKEN` win over a saved pairing for that launch. Do not set them when you intend Demo; `sim-demo` sets only `VIBEBUDDY_DEMO=1`.
- Demo `decide` always looks like success (`.received`) and ignores allow vs deny. Prove chrome, not decision semantics — those belong to [remote-approval](./remote-approval.md).
- Watch Demo (`VIBEBUDDY_WATCH_SCENARIO`) is a different entry point. Do not mark Watch pages verified because iPhone Demo launched.
- `noData` Watch shots intentionally ignore `VIBEBUDDY_DEMO` (`tools/watch-qa-shots.sh`). Do not mix that mode into this recipe.
