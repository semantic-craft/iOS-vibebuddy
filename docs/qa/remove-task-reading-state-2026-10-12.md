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

Source implemented and native isolated flow checked. The owner subsequently
confirmed there was no other device acceptance and requested installed replacement.
Signed Release 1.3.47 (65), source `725098c7`, was installed at
`/Applications/VibeBuddyMacApp.app` on 2026-10-12 at 13:38 UTC. Candidate and
installed executable SHA-256 match:
`1e165dfca30727e78c03c155a5c30dcd76204b75117e9f9e44adf69a1d97da5f`.

Installation receipt and logs are retained under
`/Users/xianweizhang/Projects/_shared-work/iOS-vibebuddy/20261012-no-read-state-install/`.
`receipt-retry.json` reports installed/complete. The initial attempt safely
stopped before replacement because the previous app did not exit after SIGTERM.
Its verified process was terminated before retry; the leftover isolated process
was also verified and terminated. The installer verified the new service on 9876.
No production token was changed.

Installed native AX and screenshot show Inbox badge 4, first-up 1 / 4, and
649 completed results separately (8 working at the final observation). Thus
completed results no longer inflate the installed dashboard's pending badge.
The UI tool exposes the dashboard window but not the system status item;
agent-side direct visual verification of the menu-bar icon was unavailable. Do not
conflate the shared counter implementation or dashboard evidence with that check.
The summary also shows the untranslated phrase `649 done`.
No physical iPhone/Watch acceptance, provider/audio acceptance or release is claimed.

Owner acceptance: on 2026-10-12, after the installed-app report identified the
menu-bar visual check as the remaining item, the owner confirmed “验收完了”.
The installed menu-bar acceptance is therefore closed by user confirmation,
not by an agent screenshot or additional device test.
