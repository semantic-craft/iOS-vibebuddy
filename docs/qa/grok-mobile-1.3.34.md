# Grok monitoring mobile installation and audio regression — 2026-10-02

Follow-up: [Mac 1.3.42 (60) is now installed](grok-mac-1.3.42.md), Grok
monitoring is enabled, and the actual installed HTTP/WebSocket snapshots carry
the new status. The Mac 1.3.41 paragraph below records the earlier phone-only
delivery state.

## Delivered source

The clean integration branch `codex/grok-monitoring-release` starts at
`origin/main` commit `75751e96`. It carries the completed Grok monitoring work
from GROK-01/02/03/04 and preserves the newer Cursor discovery and iOS parity
changes already on main. The phone and its four extension/watch targets all
use version **1.3.34 (69)**.

The audio test correction is in `c5d459d9`, with retained-player assertions in
`ab07d86e`. Both commits were pushed to the verified origin branch. This is a
branch delivery, not a merge into main or an App Store/TestFlight upload.

## Why the two audio tests failed

The original tests blocked the main actor for 1.2 seconds, assuming the
one-second synthesized WAV had completed. A clean integrated baseline
reproduced five failed assertions across these two tests:

- `testResumeAfterNaturalCompletionDoesNotReplay`
- `testInterruptionAfterCompletionDoesNotReplay`

The probe showed the native player still reporting `isPlaying == true` at
`currentTime == duration == 1.0`; yielding another 30 milliseconds did not
establish completion. Waiting for actual native completion made the original
pause/resume check pass. The assumed wall-clock delay was not evidence that
playback had finished; no production `PhoneAnnouncer` change was warranted.

The tests now wait for `AVAudioPlayerDelegate.audioPlayerDidFinishPlaying`
with a bounded XCTest expectation. They assert that the announcer still holds
the same completed player, that pause/interruption actually takes effect, and
that resume does not replay it. This preserves the original completion-before-
poll race rather than allowing an idle no-op to pass. Diagnostic probes were
removed.

## Verification

Validation used the clean worktree, not the unrelated pending changes in the
primary checkout.

- Latest full iOS simulator suite at `ab07d86e`: **184 tests, 5 skipped,
  0 failures**, `xcodebuild` exit 0 and `TEST SUCCEEDED`.
- All six `PhoneAnnouncerPlaybackTests` passed independently with the final
  assertions. Both Grok phone tests also passed in the full suite.
- Mac Grok monitoring/session/ACP and hook installer checks: **68 tests in
  five suites passed**.
- Signed iPhone Debug build: `BUILD SUCCEEDED`. Product audio code is unchanged
  by the test correction; the installed build contains the Grok phone feature.

The five skips require explicitly configured real-provider credentials,
isolated real-agent service data, or real-device microphone access. They are
not the two repaired playback tests. After the suites completed, optional
`simctl diagnose` collection stalled; only those worktree-specific diagnostic
collectors were stopped, and `xcodebuild` completed successfully.

## Phone installation

`devicectl` installed `com.vibebuddy.app` on the paired **Hermes** iPhone and
successfully launched it. A fresh device app inventory confirmed version
**1.3.34**, build **69**. This is a development-signed installation.

Computer Use reached iPhone Mirroring, but it reported that mirroring had
ended because the phone was in use. No visual phone acceptance or owner
acceptance is claimed. Earlier isolated daemon/simulator Grok flow acceptance
is recorded in [the GROK-04 record](../agents/grok-ios-acceptance-2026-10-02.md).

The installed shared Mac app remains **1.3.41** and was not replaced in this
phone delivery. The new phone connection-status card requires a Mac build
that sends `Snapshot.grokMonitoring`; installation on the phone alone does
not upgrade that Mac service.

## Review and evidence

Standards and Spec reviews independently found that the first corrected
tests could pass if commands became idle no-ops. The retained-player and
paused-state assertions resolve that finding; both reviewers confirmed no
remaining actionable findings. Their reviews were static; execution evidence
was collected by the main task.

Selected baseline, final test, Mac check, build and install/launch logs are
preserved under
`~/Projects/_shared-work/iOS-vibebuddy/2026-10-02-grok-mobile-release/`.
Worktree originals are in `.scratch/grok-release/`. The phone app inventory
containing other installed apps was not copied into the evidence archive.
Unrelated primary-checkout changes were preserved and excluded.
