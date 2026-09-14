# VibeBuddy 1.3.17 store screenshots

Captured on 2026-09-15 from running native apps in isolated Demo mode. No UI was generated, redrawn, blurred or composited.

| Platform | Build | Per language | Size | Destination |
| --- | --- | --- | --- | --- |
| iPhone | 1.3.17 (46) | 3 | 1320 × 2868 | App Store iPhone 6.9-inch |
| Watch | 1.3.17 (46) | 3 | 416 × 496 | App Store Apple Watch Series 11 |
| Mac | 1.3.19 (31) | 2 | 1145 × 768 | GitHub release; not Mac App Store |

English and Simplified Chinese are included. `manifest.json` records each file hash and dimensions. The mobile source is `3ae2027586f249bf160bcc0b50e857d58e268eaa`; its VibeBuddyApp and VibeBuddyKit trees match the build-46 release source. A Release simulator build completed successfully before capture. The Mac screenshots use a separately identified copy of the installed 1.3.19 app.

## Privacy and representation

All tasks, project labels, code examples, account-plan labels and quota values are built-in sample fixtures. No real session history, personal account readings, host names, private paths, pairing QR codes or credentials were captured. Mac ran with `VIBEBUDDY_DEMO=1`, which skips the production daemon and data polling. Mobile apps used their Demo launch inputs.

The screenshots show actual UI, including some English labels in the Chinese locale. Watch images show task/result access and the in-app quota page, not watch-face complications. The Mac Inbox's unavailable Recap row is a Demo limitation, not evidence for live Recap behavior. Screenshots do not prove live notification delivery or device acceptance.

Dimensions were checked against [Apple screenshot specifications](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications/). Watch uses one consistent size across both languages. Mobile JPEGs contain three color components and no alpha channel.

## Capture inputs

- iPhone: `VIBEBUDDY_DEMO=1`, page unset / `task/todo-app` / `usage`.
- Watch: `VIBEBUDDY_DEMO=1`, scenario `normal`, page `home` / `quota`; task `demo-watch-docs` for result detail.
- Language: `-AppleLanguages (en)` or `(zh-Hans)`, with matching locale.
- Screenshots were taken only after checking that launch transitions had settled; transient and wrong-size captures were replaced.

Upload and review submission status are recorded separately; these local files alone do not indicate App Review approval.

## Upload result

All 12 mobile screenshots were accepted by App Store Connect on 2026-09-15: three iPhone and three Watch images for each locale. iPhone order is Inbox, Task, Usage; Watch order is Tasks, Result, Usage. Four Mac screenshots are attached to the existing 1.3.19 GitHub release, whose notes now describe the major changes since 1.3.12.

Mobile 1.3.17 (46) was submitted to App Review on 2026-09-15. Submission is not approval or confirmation of a live App Store release.
