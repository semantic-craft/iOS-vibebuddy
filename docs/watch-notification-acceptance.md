# Watch notification release acceptance

Watch notifications, haptics and approval actions are release functionality. A passing development build or an APNs `accepted` response alone does not complete release acceptance.

## Package and configuration

- The acceptance build is the one the owner actually runs day to day: a development-signed install pushed to the phone with `devicectl` (the Watch app rides along). A development build holds a **sandbox** APNs token, so the Mac provider must run on sandbox for that phone (`sandbox: true` in its local `apns.json`, or `APNS_SANDBOX=1` for that process). Record the version/build installed on both devices and the provider environment used.
- The push environment and the build's signing must match; a mismatch answers every push with `BadDeviceToken` and nothing reaches the wrist. Do not read that as a Watch defect.
- The distribution build (`tools/archive-ios.sh`, production APNs, Time Sensitive entitlement) is for App Store Connect. Uploading it is a submission step, not part of this acceptance; TestFlight is not required.
- Use the owner's existing local APNs configuration. This does not authorize bundling credentials or a project-operated relay; ADR-0013 still applies.

## Physical gate

1. Keep the phone online but locked. Wear and unlock the Watch, return to its watch face, and disable Focus on both for the controlled test. Confirm VibeBuddy notifications are enabled on the phone and mirrored to the Watch.
2. Trigger one new harmless approval in a real supported agent session. Record its unique marker, pending approval identity and time. Wait beyond phone suspension; an open foreground stream is not evidence of closed-app push.
3. Record the matching APNs result, then ask the owner to confirm both a visible Watch notification and physical vibration. `accepted` only means Apple accepted the send.
4. Approve on the Watch. Verify the same approval disappears on the Mac and the real agent returns the unique command output. A phone tap or a card visible only after opening the Watch app does not satisfy this step.
5. Reopen the phone and ensure the already-announced wait is not announced again. Restart the Mac normally with the saved config, then repeat one fresh approval to verify registration/configuration survives outside a temporary launch environment.

Record candidate identities, push environment, direct service evidence and physical observations in the release's local acceptance record. A failure or unavailable device keeps this gate pending; do not label the official Watch flow accepted or archive its outstanding task on packaging evidence alone. A development-signed install also lets the wrist's own diagnostics be pulled off the phone (`Library/Application Support/watch-navigation.json` in the app container), which is the third artifact; the sequence `notification.action-decide` → `banner.action-held` → `banner.action-sent` shows the tap travelled from the wrist. Passed on 2026-09-23 03:08 with iOS 1.3.28 (58): push accepted 03:08:11, wrist sent 03:08:16, Mac cleared by 03:08:30, phone locked throughout.

## Notification routing

When iPhone is unlocked, notifications normally appear there. With iPhone locked/asleep and Watch unlocked, the system routes them to Watch. The phone's connectivity, Watch mirroring settings and Focus remain relevant. See [Apple's notification routing and settings](https://support.apple.com/108369).

The mirrored notification and its short-look haptic are delivered by the system. VibeBuddy's Watch notification scenes supply long-look content; its foreground state haptics use the existing Watch relay. Those paths must not be treated as equivalent acceptance results.
