# Mac signing recovery

## Moving to a new Mac

Check the three prerequisites again on the new machine. A working `xw-notary`
profile can be reused; do not overwrite it merely because the Mac changed.
Run `tools/fetch-mac-cloudkit-profiles.sh` to register the new Mac when necessary
and refresh profiles for its signing certificates. An old embedded CloudKit
profile is insufficient if it does not include the new Developer ID certificate.

If the old Sparkle key is unavailable, rotation needs an explicit compatibility
check against a trusted, previously published app. Sparkle 2.9.6 validates the
new app against the old app's **designated code-signing requirement**, and also
requires the new embedded EdDSA key to verify the new archive. A certificate
fingerprint change alone does not establish whether that requirement matches.
Never weaken or remove the requirement to make a rotation pass.

For the 2026-10-01 migration, v1.3.37's requirement binds the bundle identifier,
Developer ID certificate type, and Team ID rather than a certificate fingerprint.
Its feed does not require signed-feed or pre-extraction validation. The replacement
public key is in `project.yml`; the private key stays in the login Keychain.
Keep the published baseline DMG, verify its SHA-256 against the GitHub asset,
mount it read-only, then run the cryptographic rotation check after signing the
candidate and generating its appcast. Mount the candidate DMG read-only too:
the second app argument must come from that DMG, not a separate build directory.

```bash
swift tools/verify-sparkle-rotation.swift \
  /path/to/published/VibeBuddyMacApp.app \
  /path/to/mounted-candidate/VibeBuddyMacApp.app \
  /path/to/candidate.dmg '<sparkle:edSignature from candidate appcast>'
```

This checks the old designated requirement and the archive's new EdDSA signature.
It does not install an update: still perform the older-app **Check for Updates…**
acceptance when publishing. Signing-recovery packages built with an existing
version number are verification-only; never overwrite an existing release asset
or publish them as a new version. The app and DMG must both pass notarization,
stapling, and Gatekeeper, and CloudKit must remain enabled.

Reference: [Sparkle key rotation](https://sparkle-project.org/documentation/#rotating-signing-keys)
and [the 2.9.6 signing verifier](https://github.com/sparkle-project/Sparkle/blob/2.9.6/Autoupdate/SUCodeSigningVerifier.m).

## Verify the DMG, not the installed copy

After `tools/redeploy-mac.sh` the installed app is a local Developer ID build —
that script re-signs for a stable designated requirement
(`codesign --force --deep --sign`), it does not harden the runtime and it does
not notarize. So this is **expected** and is not a release defect:

```console
$ spctl -a -vv /Applications/VibeBuddyMacApp.app
/Applications/VibeBuddyMacApp.app: rejected
source=Unnotarized Developer ID
```

The installed copy therefore proves nothing about what shipped. Check the
published asset instead:

```bash
# --repo: this runs from a scratch dir, and the release lives on that repo
# whatever this checkout's gh default resolves to.
gh release download v<version> --repo semantic-craft/iOS-vibebuddy \
  -p 'vibebuddy-mac-v<version>.dmg'
stapler validate vibebuddy-mac-v<version>.dmg   # The validate action worked!

hdiutil attach -nobrowse vibebuddy-mac-v<version>.dmg   # /Volumes/vibebuddy <version>
spctl -a -vv "/Volumes/vibebuddy <version>/VibeBuddyMacApp.app"
# accepted, source=Notarized Developer ID
hdiutil detach "/Volumes/vibebuddy <version>"
```

`xcrun notarytool history --keychain-profile xw-notary` is not a substitute for
this. An `Accepted` row means Apple accepted the submission and nothing more;
`stapler validate` is what shows the ticket actually made it into the file you
are holding. An unstapled DMG still passes Gatekeeper *online*, so that gap does
not surface on the release machine — it surfaces on a first launch with no
network, which is why [the release script](sparkle-setup.md#what-the-script-does)
staples both the app and the DMG.
