# Watch notification release acceptance

Watch notifications, haptics and approval actions are release functionality. A passing development build or an APNs `accepted` response alone does not complete release acceptance.

## Package and configuration

- Run `tools/archive-ios.sh`. The exported iPhone must use distribution signing, production APNs and the Time Sensitive entitlement. The embedded Watch must be distribution-signed, match the iPhone version/build and name the correct companion app.
- Install the release candidate through TestFlight. Confirm the companion Watch app has updated too. Record the version/build actually installed on both devices.
- Pair that iPhone with the Mac candidate and confirm a current device registration. The Mac provider must use **production** APNs for a TestFlight/App Store token (`sandbox: false` in its existing local config, or `APNS_SANDBOX=0` for that process).
- Keep development/sandbox acceptance separate. Switching the provider to production while the phone still runs a development build does not test this release. Never copy a sandbox registry into the production test and call it a new registration.
- Use the owner's existing local APNs configuration. This does not authorize bundling credentials or a project-operated relay; ADR-0013 still applies.

## Physical gate before App Store submission

1. Keep the phone online but locked. Wear and unlock the Watch, return to its watch face, and disable Focus on both for the controlled test. Confirm VibeBuddy notifications are enabled on the phone and mirrored to the Watch.
2. Trigger one new harmless approval in a real supported agent session. Record its unique marker, pending approval identity and time. Wait beyond phone suspension; an open foreground stream is not evidence of closed-app push.
3. Record the matching APNs result, then ask the owner to confirm both a visible Watch notification and physical vibration. `accepted` only means Apple accepted the send.
4. Approve on the Watch. Verify the same approval disappears on the Mac and the real agent returns the unique command output. A phone tap or a card visible only after opening the Watch app does not satisfy this step.
5. Reopen the phone and ensure the already-announced wait is not announced again. Restart the Mac normally with the saved config, then repeat one fresh approval to verify registration/configuration survives outside a temporary launch environment.

Record candidate identities, push environment, direct service evidence and physical observations in the release's local acceptance record. A failure or unavailable device keeps this gate pending; do not label the official Watch flow accepted or archive its outstanding task on packaging evidence alone. Uploading to TestFlight for this validation is distinct from submitting the app for public release.

## Notification routing

When iPhone is unlocked, notifications normally appear there. With iPhone locked/asleep and Watch unlocked, the system routes them to Watch. The phone's connectivity, Watch mirroring settings and Focus remain relevant. See [Apple's notification routing and settings](https://support.apple.com/108369).

The mirrored notification and its short-look haptic are delivered by the system. VibeBuddy's Watch notification scenes supply long-look content; its foreground state haptics use the existing Watch relay. Those paths must not be treated as equivalent acceptance results.
