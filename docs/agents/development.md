# Development entry points

Use this map to find the owning source and the smallest relevant local check.
Commands run from the repository root. Product behavior still needs the affected
real-agent/native flow in [verify-vibebuddy](skills/verify-vibebuddy/SKILL.md).

## Owning sources and change boundaries

| Change | Owning source | Check first; then exercise |
| --- | --- | --- |
| Shared wire models, presentation rules, voice adapters | [VibeBuddyKit](../../VibeBuddyKit/Sources/VibeBuddyKit), [package](../../VibeBuddyKit/Package.swift) | `tools/check.py kit --filter <test>`; affected Mac/phone consumers |
| Session observation, reducer, local HTTP/WS, history CLI | [MacCore](../../VibeBuddyMac/Sources/VibeBuddyMacCore), [CLI](../../VibeBuddyMac/Sources/vibebuddy-mcp), [package](../../VibeBuddyMac/Package.swift) | `tools/check.py mac --filter <test>`; isolated daemon with the actual agent |
| Mac dashboard/settings/Glance | [Mac sources](../../VibeBuddyMacApp/Sources) | `tools/check.py mac-build`; isolated native UI; `settings` or `integration` for their specific state regressions |
| Phone, Watch, widget | [Phone](../../VibeBuddyApp/Sources), [Watch](../../VibeBuddyApp/Watch), [shared](../../VibeBuddyApp/Shared) | `tools/check.py ios-build`; the changed native/device flow |
| Hook payload or installation | [hooks](../../hooks), [HookInstaller](../../VibeBuddyMac/Sources/VibeBuddyMacCore/HookInstaller.swift) | `tools/check.py mac --filter Hook`; real hook delivery, not only registration |
| Local Mac installation | [redeploy-mac.sh](../../tools/redeploy-mac.sh), [transaction](../../tools/lib/install-mac-app.sh), [macOS effects](../../tools/lib/mac-app-runtime.sh) | `tools/check.py deployment`; authorized installed-app acceptance remains separate |
| Distribution | [Mac release](../../tools/release-mac.sh), [iOS archive](../../tools/archive-ios.sh) | Their signature/artifact checks and [release runbook](../sparkle-setup.md); uploading and publishing need authorization |
| Check runner or SwiftPM pin preservation | [check.py](../../tools/check.py), [pin wrapper](../../tools/with-resolved.py) | `tools/check.py workflow`; replay the affected real command |
| Rules, navigation, task status | [AGENTS.md](../../AGENTS.md), [backlog](../planning/backlog/README.md), [QA](../qa) | `tools/check.py docs`; inspect wording and rendered layout |

XcodeGen's [Mac](../../VibeBuddyMacApp/project.yml) and
[iOS](../../VibeBuddyApp/project.yml) `project.yml` files own project settings,
versions and generated Info.plists. Edit those specifications; regenerate the
ignored `.xcodeproj` and Info.plist outputs. `dist/` contains build products,
not source. See [domain vocabulary](../../CONTEXT.md) and relevant [ADRs](../adr)
when changing behavior. A shared model change can affect every native surface;
a UI-only edit normally stays in its owning app.

## Local checks

`tools/check.py --list` is the executable list of profiles and their limits.
Use `--filter` for a known Swift regression; omitting it runs that package's suite.
The runner stops on the first failure and records remaining commands as not run.
A Swift run that exits successfully but executes no tests fails the check.
The runner uses Python 3.9+; `--prepare` and the bundled CLI build also use Python.
SwiftPM can prune the GUI-only Sparkle/MenuBarExtraAccess pins when building the
Mac CLI. The pin wrapper restores only that known transformation; unexpected
dependency changes remain visible and fail the command, with the original saved.
There is no implicit install, production daemon, upload or cloud CI step.

Each run creates `.scratch/checks/<UTC timestamp>-<profile>/results.json` and
numbered logs. The report contains HEAD, branch, working-tree status and a hash
of the tracked diff plus untracked sources, actual commands, exit codes, elapsed
seconds and limitations. A source change during execution makes the run fail;
inspect the change before attributing a result to a version. Generated/ignored
build products are outside that source fingerprint. The default logs are local
and may include compiler paths; review them before sharing.

For checks whose evidence must survive checkout cleanup, choose a **new** directory:

```bash
tools/check.py deployment --output "$HOME/Projects/_shared-work/iOS-vibebuddy/<run-id>/deployment"
```

This stores the result and logs directly at the durable location. The directory
must be new, and repo-local output must be gitignored. The runner verifies local
Markdown link targets; it does not fetch external URLs, validate anchors or render
pages. `deployment` tests use disposable app directories and an ad-hoc signed
fixture on macOS; they never launch the installed app or bind `:9876`.

## Installation and closeout

`tools/redeploy-mac.sh --prepare` builds in a unique `.scratch/deploy/` directory,
signs and strictly verifies the candidate, and records source fingerprints,
version/build and executable SHA-256. It does not install or launch it. If the
source changes during preparation, rebuild before installation.

After preparation, obtain installation authorization and complete the fresh
peer/device check in [the shared-app runbook](../sparkle-setup.md#the-installed-app-is-shared):

```bash
tools/redeploy-mac.sh --install /absolute/candidate/VibeBuddyMacApp.app --peer-check-complete
```

The flag attests to completed coordination; it neither grants permission nor
detects hardware use. A directory lock in `/Applications` serializes this installer
across checkouts. Other installation methods and Sparkle do not honor that lock,
so coordination remains necessary. An existing lock blocks installation; after a
crash, inspect its `owner.txt` before removing a stale lock.

The installer copies and strictly verifies the candidate before stopping the app,
renames the old bundle to `previous.app`, and checks that exactly one process at
the installed path owns `:9876` and returns health `ok`. A launch/health failure
restores and, if previously running, relaunches the old bundle. It reports failure
even if rollback succeeds; it does not silently remove CloudKit capabilities.
Recovery bundles remain at the printed `.VibeBuddyMacApp.app.install.<id>` path.
SIGKILL/power loss cannot run rollback; use the path in the lock's `owner.txt` to
recover after coordinating with peers. If rollback cannot stop the candidate or
restore the old bundle, it reports failure and preserves the recovery directory.
Logs and backups do not prove phone/Watch or real-agent acceptance.

Keep the current state in the existing ticket or a `docs/qa/<work>.md` record:

- Source commit/range and dirty-source fingerprint; link the actual check report.
- Candidate version/build and artifact hash when an app/package was produced.
- Checks passed, checks not run and the exact remaining device/provider boundary.
- Separate modified, verified, committed, pushed, installed, published and owner
  accepted states. State the next unfinished action only when one remains.

Tracked QA summaries contain sanitized conclusions and durable evidence locations.
Large/private logs and screenshots belong under
`~/Projects/_shared-work/iOS-vibebuddy/<run-id>/` when they must persist; keep them
out of Git. `.scratch/` handoffs are local navigation aids, not the only copy of a
settled decision or acceptance result. Before a completed ticket is removed,
link its durable QA record from the PR/commit or release record; Git retains the
removed ticket's history. The [handoff skill](skills/vibebuddy-handoff/SKILL.md)
adds source-session identity when another agent must continue.
