# Remove task reading state — 2026-10-12

Owner request: remove read/unread from tasks. The screenshot's 500 was the old
pending union: 4 needs-you plus 496 unread completions. No historical result is deleted.

Done is independent of the legacy read bit. Pending navigation, project pending
counts and the menu badge include only questions, approvals and terminal failures.
Finished tasks age out after 24 hours even when followed. Mac, phone and Watch no
longer offer reading-state controls; viewport reading does not acknowledge a task.
The periodic completion-reminder loop is removed. Result viewing, one-shot notices
and manual/automatic speech remain. Existing transport/storage fields are retained
for installed clients and delivery bookkeeping, not used to classify pending work.

## Evidence

Base: `5395b621`. Changes tested in the primary checkout. Each report below records
the source fingerprint; later changes only update regression expectations and this record.

- Kit: 113 tests passed, including 496 completions + 4 waits => pending count 4.
  Report: `.scratch/checks/20261012T132612.381511Z-kit/results.json`.
- Mac: 37 tests passed for dashboard scope, menu feed, activity push and Copilot
  history. Report: `.scratch/checks/20261012T132929.339933Z-mac/results.json`.
- Mac build passed: `.scratch/checks/20261012T132528.467963Z-mac-build/results.json`.
- iPhone/Watch simulator build passed:
  `.scratch/checks/20261012T132639.469208Z-ios-build/results.json`.
- Native isolated app: `com.vibebuddy.e2e.no-read-state`, port 18769, separate
  runtime root, audio/notifications disabled. Real current Codex rollout was
  observed as Working. A hook-seeded completion fixture was observed as Done.
  AX confirmed `0 need you 1 done 1 working`, result context menu without read
  actions, and detail `Outside pending · 0 remaining · All sessions` with Next
  pending disabled. The fixture still carried the legacy unread bit: it did not
  create a pending item. Result/replay controls remained; this fixture had no
  independently verified completion body. This is not successful speech evidence.
  Local evidence: `.scratch/no-read-state/snapshot-after.json`. Only the isolated
  app PID was stopped afterward; production was not stopped.

The initial broad Kit run also exposed an unrelated existing `WireCodingTests`
expectation listing older account providers. No all-tests-green claim is made.
Earlier runs with old reading-state expectations or transient Package.resolved
fingerprint changes are superseded by the scoped passing reports above.

## Delivery boundary

Source implemented and native isolated flow checked. No installed-app replacement,
physical iPhone/Watch acceptance, provider/audio acceptance or release is claimed.
The shared-app peer check found other active sessions; their device ownership was
not confirmed. Follow `docs/sparkle-setup.md`, "The installed app is shared", before
replacing `/Applications/VibeBuddyMacApp.app`. No production token was changed.
