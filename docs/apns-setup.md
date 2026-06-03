# APNs setup (closed-app push)

**Status:** the provider auth chain is **verified working** — a signed ES256 JWT
from the real .p8 was accepted by APNs sandbox (returned `BadDeviceToken` for a
dummy token, which means the key/JWT/team/connection are all correct). What's
left is getting a real device token (iOS signing + run on device).

## The values

| Field | Value | Where |
|---|---|---|
| Key ID | `9L99B95NNM` | the APNs key page (also in the .p8 filename) |
| **Team ID** | **`LQAVR62TK2`** | the signing cert's **OU**, not the CN parenthetical! |
| Bundle ID | `com.vibebuddy.app` | App ID (must have Push capability) |
| .p8 | `~/Library/Application Support/vibebuddy/apns/AuthKey_9L99B95NNM.p8` | copied from Downloads |

> ⚠️ **Team ID gotcha:** `security find-identity` shows `(B6NUMVUKU7)` in the cert
> *name*, but that is **not** the Team ID. The Team ID is the cert's **OU**:
> `security find-certificate -a -c "Apple Development" -p | openssl x509 -noout -subject`
> → `OU=LQAVR62TK2`. Using the wrong one gives `403 InvalidProviderToken`.

## Mac config

Two ways; `APNsConfig.load()` tries env first, then the file.

- **CLI (`vibebuddyd`)** — env vars: `APNS_TEAM_ID`, `APNS_KEY_ID`,
  `APNS_BUNDLE_ID`, `APNS_KEY_PATH`, `APNS_SANDBOX=1`.
- **Menu-bar app (GUI)** — a JSON file, since GUI apps don't inherit shell env:
  `~/Library/Application Support/vibebuddy/apns.json` →
  `{ "teamID", "keyID", "bundleID", "keyPath", "sandbox" }`. **Already written.**

The daemon logs `apns: on` at startup when configured.

## iOS (the remaining step — needs a device)

In `VibeBuddyApp/project.yml`, on the `VibeBuddyApp` target, switch to real signing:
```yaml
    settings:
      base:
        DEVELOPMENT_TEAM: LQAVR62TK2
        CODE_SIGN_STYLE: Automatic
        CODE_SIGN_ENTITLEMENTS: VibeBuddyApp.entitlements   # aps-environment
        # remove CODE_SIGNING_ALLOWED: NO
```
`xcodegen generate`, open in Xcode, plug in the iPhone, pick it as the run
destination, and Run. Xcode registers the device + makes the provisioning
profile. The app registers for push, gets a token, and uploads it to the Mac's
`POST /device`.

## End-to-end

device token uploaded → kill the app → on the Mac trigger a `needsResponse`
(a real Claude Code permission prompt, or `curl` a Notification hook) → the
phone shows the push while the app is closed. Use `production` in the entitlement
for App Store/TestFlight builds (and unset `sandbox` on the Mac).
