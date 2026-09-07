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

## Real-device build 12 acceptance

- Installed archived build 12 on the acceptance iPhone and its Apple Watch without
  uninstalling or clearing data; device tools and Xcode confirmed Watch 1.3 (12).
- Watch app screenshot at 14:08 showed five working tasks and real Codex/Claude
  quota. The connected iPhone dashboard at 14:11 showed the same five working,
  six completed and one idle projection.
- Watch face screenshot at 14:13 showed a real followed-task complication and
  quota complications (Codex 55%, Claude 50%); these were physical-device captures.
- Terminated iPhone build 12 process at 14:12. One aggregate activity remained;
  tapping it cold-launched the app, reconnected to the paired Mac and received
  six working tasks. At 14:16 the single Island count changed from five to four as real tasks
  changed after recovery. Watch also updated to three working tasks and fresh quota.
- The second iPhone was not modified. Wrist haptic perception and background APNs
  delivery were not exercised by this regression acceptance.

## Release state

Build 12 uploaded at 14:09, completed Apple processing, and replaced build 11.
At 14:21 App Store Connect confirmed submission and **Waiting for Review**.
Submission ID: `6da289ac-2278-4925-9e93-6f23bdad3005`.
Build ID: `576acbd6-876a-49ee-89bd-620e885b8451`.
Release remains automatic after approval; the new version is not yet public.
Review notes include the public source repository (iOS, watchOS, widgets and Mac),
the built-in Demo, the tested recovery fix and the public APNs delivery limits.
