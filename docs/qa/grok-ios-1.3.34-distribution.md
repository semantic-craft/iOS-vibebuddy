# iOS 1.3.34 App Store submission — 2026-10-02

## Current delivery

VibeBuddy **1.3.34 (69)** was submitted directly to App Store review at
**11:39 Asia/Shanghai on 2026-10-02**. App Store Connect visibly reports
**Waiting for Review**. It is not yet approved or available on the store.
Automatic release after approval and immediate availability to all users
remain selected. No beta group or tester was added.

- App: `6777469338`, bundle `com.vibebuddy.app`.
- Build: `b7c522b7-ac03-407b-8429-2f72ef3dd799`.
- Submission: `18d03d21-8c51-4abe-b908-2e917dd1a386`.
- [Apple review record](https://appstoreconnect.apple.com/apps/6777469338/distribution/reviewsubmissions/details/18d03d21-8c51-4abe-b908-2e917dd1a386).

The prior pending 1.3.33 (68) submission was withdrawn to replace it with
this update. Its submission ID was `4be43495-6219-4ea2-8349-214c724608ee`.
The new English and Simplified Chinese release notes include both Grok
monitoring and the inherited, previously unpublished 1.3.33 improvements.
Descriptions, screenshots, reviewer contact, privacy and pricing were preserved.

## Artifact and verification

The archive was built from clean branch `codex/grok-monitoring-release` at
`425d5d40`; later changes only record distribution evidence and release notes.
The project archive script completed successfully using Bash 5 with Apple's
command-line tools first in PATH. The exported IPA uses Apple Distribution
signing, production APNs, Time Sensitive Notifications and `get-task-allow=false`.
All five phone/widget/watch/notification products have version 1.3.34 (69),
and strict signature verification passed.

Xcode's existing Apple account uploaded the archive successfully at **11:29:56**.
The upload command exited 0 with `Upload succeeded` and `EXPORT SUCCEEDED`.
Apple processing completed and build 69 was selected in the App Store version.
The final review page confirms the same 1.3.34 (69) association.

[Mobile installation and test evidence](grok-mobile-1.3.34.md) records the full
iOS run: 184 tests, five environment-dependent skips, zero failures. No product
code changed between that validation and the distribution archive.

## Runtime boundaries and evidence

The Grok status needs Mac 1.3.42 or newer. That version is installed locally;
this operation does not publish a new Mac DMG or update feed. Existing core
features remain compatible with the publicly released Mac companion.
[Installed Mac acceptance](grok-mac-1.3.42.md) records real HTTP/WebSocket and UI
status. Physical phone visual acceptance remains unavailable; the prior
development installation and launch do not establish it.

Selected logs, IPA, signature/hash JSON and the submission screenshot are in
`~/Projects/_shared-work/iOS-vibebuddy/2026-10-02-grok-mobile-release/`:
`ios-distribution-build.log`, `ios-upload.log`,
`ios-distribution-verification.json`, `VibeBuddyApp-1.3.34-69.ipa`,
`app-store-1.3.34-submitted.png`.
