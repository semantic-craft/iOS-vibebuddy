# 1.3.17 integrated acceptance

Candidate: Mac build 29; iPhone, iPhone widget, Watch and Watch widget build 46. Integrates PRs #195, #196 and #197 with the Watch notification/detail fixes in #198.

## Verified before packaging

- Integrated VibeBuddyKit: 557 tests passed.
- Integrated iPhone simulator: 11 selected tests passed (AccountQuotaTests, WidgetQuotaStoreTests and WatchRelayTests.testWatchRefreshFetchesNewAuthorityContentWithoutSendingAnAnswer).
- Native iPhone simulator connected to the running Mac, without demo data: Usage rendered Codex, Claude and Grok readings; unavailable providers showed their reason. The installed home-screen Usage widget displayed Claude weekly 44% and short-window 97%, matching the contemporaneous app reading. This is simulator UI plus live Mac data, not physical widget acceptance.
- PR review found callback completion preceding intent persistence and stale snapshot notification side effects. Both were fixed. The stale-snapshot regression also exposed an initial timestamp boundary; first load and connection reset now start without a server timestamp. All 19 DashboardStore/Watch refresh tests passed after correction.
- Standards/spec review: the two reported races are addressed; production physical acceptance remains distinct from these tests.

## Physical Watch evidence carried into this candidate

Development build 44, real Codex task: owner confirmed iPhone remained locked, the Watch notification opened the matching task detail, and the newest generated summary appeared. The observed refresh request/reply interval was approximately 0.82 seconds. The Mac completion remained unread after viewing/refreshing.

Earlier owner observations confirmed haptics, working task list, explicit mark-as-read and removal of Recap. These observations do not establish every approval/question workflow or production APNs behavior.

Local traces are retained under `.scratch/watch-task-entry/` (build44 notification, tap and refresh JSON) and `.scratch/release-1.3.17/` (integrated build/test logs). No pairing tokens or notification device identifiers are included here.

## Distribution gate

Build 45 iOS archive/export completed with distribution signatures, production APNs, Time Sensitive Notifications, matching embedded Watch version/build and companion identity. Build 45 was uploaded successfully but was superseded by the reviewed build 46 candidate. Build 46 archive/export is being repeated. TestFlight upload is a separate operation from public App Store submission.

The production physical gate in [watch-notification-acceptance.md](../watch-notification-acceptance.md) remains pending: install the TestFlight candidate on iPhone and Watch, verify locked-phone notification and vibration, approve a real agent request on Watch, and verify the Mac/agent receipt and persistence after restart. Development acceptance above does not close this gate.
