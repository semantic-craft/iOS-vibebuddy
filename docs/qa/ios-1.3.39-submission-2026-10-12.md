# iOS 1.3.39 (74) — 2026-10-12

Owner authorized App Store CLI submission, including removal of read/unread and
exclusion of read-only historical failures from pending counts. This is an iOS
release; the installed Mac 1.3.47 (65) has the earlier reading-state change only.

## Changes and checks

History-only rows present in Done without changing stored failure evidence.
They age into Older after 24 hours, even if the original lifecycle recorded a
failure or wait. Live waits and live terminal failures retain existing behavior.
No claim is made that a growing collection of unresolved live failures is bounded.

- Shared Kit targeted checks passed: `TaskPresentationTests|SessionCurrencyTests`;
  includes 500 history failures plus one live question producing pending count 1.
  Evidence: `.scratch/checks/20261012T134535.953425Z-kit/results.json`.
- iPhone/Watch simulator build passed:
  `.scratch/checks/20261012T134628.415236Z-ios-build/results.json`.
- Fresh simulator `VibeBuddy No Read State QA` launched the built app in Demo.
  Native UI tooling cannot bind Simulator on this host, so no new screenshot or
  live-agent iPhone UI acceptance is claimed. Shared projection and prior Mac
  acceptance are distinct from that gap. No new physical Watch/push/audio test.
- Documentation check passed; existing review notes were updated to remove read
  acknowledgments and describe the two changes without changing contact details.

## Store delivery

Source commit: `6780171e`. Archive export and distribution signatures passed for
app, widget and Watch. IPA SHA-256:
`7499e2d39bb5e13d967063c6b55bba947f4dfd742017123150d653e9276bc3df`.

Used the project `tools/appstore.sh` entry and asc 5.14.1 with the existing
1Password credentials. Uploaded build 74 processed as VALID; version 1.3.39
received the two release-note localizations and updated reviewer notes. Initial
readiness found missing `socialMedia` and `socialMediaAgeRestricted`; both were
set to false to match this non-social app, leaving other responses unchanged.
The resumed staging/readiness check passed. The IPA targets iPhone only
(`UIDeviceFamily = [1]`); no iPad screenshots were added.

Submitted at 2026-10-12 21:53:33 Asia/Shanghai. A separate status query confirmed
both version and submission `WAITING_FOR_REVIEW` (not approved or released).
Release type remains `AFTER_APPROVAL`.

- App: `6777469338`
- Version ID: `427d1bbc-e861-4a11-95a7-b6495c937d6a`
- Build ID: `21371032-913e-46e5-a48b-e0174730915b`
- Submission ID: `076f595e-a6e1-4a99-9815-8998b768fb9d`
- Durable evidence: `/Users/xianweizhang/Projects/_shared-work/iOS-vibebuddy/20261012-ios-1.3.39/`.

The isolated Demo simulator was shut down after checking launch. The historical-attention change was subsequently installed on Mac; see the
Mac follow-up below.


## Mac installed follow-up — 2026-10-12

Owner explicitly requested installing the historical-attention change on Mac.
Built source `b1b00f9b` without source changes, installed 1.3.47 (65) at 22:02
Asia/Shanghai. Installed and candidate executable hashes match:
`50202096ec0bdc087fc86eec187cbfd4d702f190890edba11f45ecf3b744c02d`.
The installer verified unique service ownership on 9876. The previous process
again ignored SIGTERM, so the first install stopped before replacement; its
verified PID was terminated before the successful retry.

After observers recovered, installed native AX shows the global Inbox summary
`0 个需要你 662 done 9 个进行中` and the Needs-you bucket `0`; the previous four
historical failures no longer add pending attention. This is installed dashboard
evidence, not a new direct screenshot of the system menu-bar status item.

Durable evidence:
`/Users/xianweizhang/Projects/_shared-work/iOS-vibebuddy/20261012-history-attention-mac-install/`.
The prepared candidate/build cache and failed-install staging copy were removed
following the owner's cleanup preference. The successful installation retains
its previous.app recovery copy.
