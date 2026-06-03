# APNs setup (closed-app push)

The code is scaffolded and builds. To make it actually push — phone alerted on
"needs you" even when the app is killed — you need a **paid Apple Developer
account**, then wire in the key. Steps once enrolled:

## 1. Apple Developer portal
1. **Keys → +** → enable *Apple Push Notifications service (APNs)* → download the
   `AuthKey_XXXXXXXXXX.p8` (download once!). Note the **Key ID**.
2. Note your **Team ID** (top-right of the portal). You already sign as team
   `B6NUMVUKU7`.
3. **Identifiers** → register `com.vibebuddy.app` with the *Push Notifications*
   capability.

## 2. iOS app (signing + entitlement)
In `VibeBuddyApp/project.yml`, on the `VibeBuddyApp` target:
```yaml
    settings:
      base:
        DEVELOPMENT_TEAM: B6NUMVUKU7
        CODE_SIGN_STYLE: Automatic
        CODE_SIGN_ENTITLEMENTS: VibeBuddyApp.entitlements   # already in repo
        # drop CODE_SIGNING_ALLOWED: NO
```
Then `xcodegen generate` and run **on a real device** (push doesn't work in the
Simulator). The app registers, gets a token, and uploads it to the Mac's
`POST /device`. (Use `production` in the entitlement for App Store builds.)

## 3. Mac (the .p8 key)
Launch the menu-bar app / `vibebuddyd` with these env vars set:
```bash
export APNS_TEAM_ID=B6NUMVUKU7
export APNS_KEY_ID=XXXXXXXXXX            # the .p8 Key ID
export APNS_BUNDLE_ID=com.vibebuddy.app
export APNS_KEY_PATH=/path/to/AuthKey_XXXXXXXXXX.p8
export APNS_SANDBOX=1                     # 1 for dev builds; unset for App Store
```
`APNsConfig.fromEnvironment()` picks these up; until they're set, push stays off
and nothing else changes.

## Flow
app registers → uploads device token to Mac `/device` → on each fresh
`needsResponse` transition the Mac signs an ES256 JWT and POSTs an alert to
`api.push.apple.com/3/device/<token>` → phone shows the notification.

The cryptographic core (`APNsJWT`) is unit-tested (sign + verify round-trip).
Everything downstream is plumbing that only activates once the key is present.
