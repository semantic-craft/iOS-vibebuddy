# Sparkle activation runbook (issue 07)

The Sparkle code is wired and builds (dep + `Updater` + "Check for Updates…" menu +
Info.plist `SUFeedURL`/`SUPublicEDKey`/`SUEnableAutomaticChecks`). It is **inert** until the
key + appcast below exist. Everything here needs *your* signing key and *your* host — an agent
cannot generate a private key it must not possess, host a website, or notarize under your account.

## One-time: signing key

```bash
# Sparkle ships generate_keys in its SPM artifact (path varies by checkout):
find ~/Library/Developer/Xcode/DerivedData -name generate_keys -path '*/Sparkle/*' 2>/dev/null | head -1
# Run it once. It stores the PRIVATE key in your login Keychain and prints the PUBLIC key.
./generate_keys
```

- Paste the printed **public** key into `VibeBuddyMacApp/project.yml` → `SUPublicEDKey` (then `xcodegen generate`).
- The **private** key stays in your Keychain. Never commit it.

## Per release

1. Set a real feed URL in `project.yml` → `SUFeedURL` (where you'll host `appcast.xml`), `xcodegen generate`.
2. Build + stable-sign the app: `tools/redeploy-mac.sh` (or an archive), then **notarize + staple**
   the `.app`/`.dmg` with your Developer ID (Sparkle requires a notarized, Developer-ID-signed build
   for Gatekeeper to launch the update).
3. Put the built `.zip`/`.dmg` in a `dist/` dir and generate the signed appcast:
   ```bash
   ./generate_appcast dist/      # signs each archive with the Keychain private key, writes dist/appcast.xml
   ```
4. Upload `dist/appcast.xml` + the archive to the host behind `SUFeedURL`.
5. "Check for Updates…" (menu) now works; bump `MARKETING_VERSION` for the next release.

See `dist/appcast-template.xml` for the expected shape. Sparkle docs:
<https://sparkle-project.org/documentation/>.
