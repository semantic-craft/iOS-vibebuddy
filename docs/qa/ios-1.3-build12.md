# iOS and watchOS 1.3 (12) acceptance

Date: 2026-09-07. Release candidate includes the Live Activity recovery fix from
`502defa` (integrated as `06dab57`) and Mac 1.3.3 integration from `4f9ef06`.

## Change

On relaunch, adopt an existing active/stale Live Activity and end extra activities
instead of creating another aggregate. Serialize reconciliation, end all activities
when no sessions remain, and resume push-token reporting. Restarting the dashboard
with the same pairing no longer destroys the existing activity.

All four mobile targets use version 1.3, build 12. Watch minimum OS remains 26.5.
The Mac menu entry preference is Mac-only; phone and Watch retain their task status.

## Verified

- Native ActivityKit regression run: two Live Activity tests plus five DashboardStore
  tests passed in the iOS 26.5 simulator (handoff evidence:
  `/tmp/vibebuddy-live-activity-recovery-verified.log`).
- the acceptance iPhone received a signed development build containing this fix without uninstall
  or pairing reset. The device retained its the paired Mac connection and showed real tasks.
- After terminating the app process, the existing Dynamic Island activity remained.
  Tapping it reopened the app and its real dashboard; returning Home showed one
  aggregate activity. This is visible recovery evidence, not a device registry ID
  count or proof of background APNs delivery. An app-switcher swipe was not verified.
- The same source was archived as 1.3 (12), with the iPhone widget, Watch app and
  Watch widget embedded. App Store export succeeded; distribution signatures and
  production APNs entitlement passed the archive script checks.
- Independent Standards/Spec review reported zero findings. `git diff --check` passed.

## Remaining acceptance

Watch developer transport disconnected during installation. The last readable Watch
installation was 1.3 (9); build 12 installation and real Watch task/complication
synchronization are not yet verified. Xcode asks for the unlocked Watch near the Mac.
the acceptance iPhone final-build installation and continued Live Activity state updates remain to
be checked. The second iPhone is outside this acceptance run and was not modified.

## Release state

At the live App Store Connect check, 1.3 (11) was Waiting for Review. Build 12 is
prepared to replace it after acceptance; an upload or successful build must not be
reported as review approval or public availability.
