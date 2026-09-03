# Sparkle + notarized release runbook (Mac)

The Mac app is distributed **directly** (not the Mac App Store), signed with a
Developer ID, notarized by Apple, and updated in place by Sparkle. One script does
the whole chain:

```bash
tools/release-mac.sh                  # build → sign → notarize → staple → DMG → appcast
tools/release-mac.sh --skip-notarize  # same, minus the two Apple round trips (dry run)
```

It refuses to start until the three things only *you* can provide are in place,
and prints the exact command for whichever one is missing.

## The three human prerequisites

| What | Where it lives | How to check |
|---|---|---|
| Developer ID Application certificate | login Keychain | `security find-identity -p codesigning -v` |
| Sparkle EdDSA private key | login Keychain, service `https://sparkle-project.org`, account `ed25519` | `security find-generic-password -s https://sparkle-project.org -a ed25519` |
| notarytool credentials | login Keychain, profile `xw-notary` | `xcrun notarytool history --keychain-profile xw-notary` |

**Certificate.** Xcode ▸ Settings ▸ Accounts ▸ your Apple ID ▸ Manage Certificates
▸ **+** ▸ *Developer ID Application*. Needs a paid Apple Developer Program membership.

**Sparkle key.** Run Sparkle's `generate_keys` once — it puts the **private** key in
your Keychain and prints the **public** key, which goes into
`VibeBuddyMacApp/project.yml` → `SUPublicEDKey`. Never commit the private key; an
agent must never hold it.

```bash
"$(find VibeBuddyMacApp/build/SourcePackages/artifacts -name generate_keys | head -1)"
```

The release script verifies that the key in your Keychain matches the `SUPublicEDKey`
compiled into the app, and stops if they diverge — signing an update with the wrong
key ships an update no installed copy can verify.

**Notary credentials.** Run the helper — it collects the App Store Connect API key
in macOS dialogs (a file picker for the `.p8`, then Key ID and Issuer ID) and hands
them to Apple's own tool. The key is passed by *path*: never read by the script,
never echoed, never in the process list. If you have no key yet, the first dialog
offers to open App Store Connect at the right page (Users and Access ▸ Integrations
▸ Team Keys ▸ **+**, role *Developer* or above — the `.p8` downloads exactly once).

```bash
tools/store-notary-credentials.sh
```

It verifies the stored profile against Apple before reporting success, so a typo in
the Key ID surfaces immediately rather than halfway through a release.

## What the script does

Preflight runs first (see above): it checks the certificate, the Sparkle key, and
the notary profile in that order, and the moment one is missing it calls
`needs_you()` — prints the exact command to fix it and the exact `tools/release-mac.sh`
invocation to re-run afterward, then exits (status 2) before any build happens. With
`--skip-notarize` the notary-profile check is skipped entirely (there is nothing to
verify), so a machine with only a Developer ID certificate and a Sparkle key can still
run the dry run below.

1. `xcodegen generate`, then a Release build with
   `CODE_SIGNING_ALLOWED=NO` — Xcode produces an **unsigned** `.app`. It is left
   unsigned on purpose: Xcode's own build-time signing signs `Sparkle.framework`
   but *not* the `Updater.app`, `Autoupdate`, and XPC services nested inside it —
   those stay ad-hoc from Sparkle's own binary artifact, and notarization rejects
   an ad-hoc signature outright.
2. Signs everything itself, by hand, **inside out**, because signing a nested
   bundle invalidates the seal of everything that contains it: every `.xpc` and
   `.app` inside `Sparkle.framework`'s versioned directory, then `Autoupdate`,
   then `Sparkle.framework` itself, then any other `.dylib` in `Contents/Frameworks`,
   and only last the app bundle — `VibeBuddyMacApp.app`, with the Hardened Runtime,
   a secure timestamp, your Developer ID identity, and
   `tools/vibebuddy-mac.entitlements` (microphone only — the app is not sandboxed).
3. Verifies the result: `codesign --verify --deep --strict`, plus a check that
   *every* nested Mach-O carries the runtime flag, a Developer ID authority, and a
   secure timestamp. Notarization rejects the whole submission over one un-hardened
   or ad-hoc-signed binary, and catching it locally is faster.
4. Notarizes and staples the **`.app`**, then builds and codesigns the DMG, then
   notarizes and staples the **DMG**. Both app and DMG get stapled, on purpose: the
   stapled DMG covers the download, and the stapled app inside it lets a first launch
   succeed with no network. With `--skip-notarize` both notarize/staple round trips
   are skipped outright (the app and DMG stay Developer-ID signed but un-notarized
   and un-stapled) — only this step is conditional on the flag.
5. Gatekeeper assessment: on a real run, `stapler validate` and `spctl --assess`
   against both the app and the DMG. On `--skip-notarize`, `spctl --assess` is run
   against the app anyway and its rejection is printed as *expected* — Developer-ID
   signed but not notarized is exactly what Gatekeeper is supposed to reject.
6. Runs Sparkle's `generate_appcast` over `dist/` regardless of `--skip-notarize` —
   it signs each archive with the Keychain private key and writes `dist/appcast.xml`.
   Signatures and lengths are never hand-written. `docs/release-notes-<version>.md`
   is copied next to the DMG under the same basename, and the feed links to it as the
   update's release notes — so that `.md` is published to `gh-pages` alongside
   `appcast.xml`.
7. Summary. On `--skip-notarize` the script prints a "dry run — do NOT publish this
   DMG" warning and exits; a full run instead prints the exact `gh release create`
   and `gh-pages` commands for you to run by hand — publishing stays manual either way.

## Hosting

- **Feed** — `appcast.xml` *and* `vibebuddy-mac-v<version>.md` on the repo's
  `gh-pages` branch, served at the `SUFeedURL` in `project.yml`:
  `https://semantic-craft.github.io/iOS-vibebuddy/appcast.xml`.
  Enable it once at Settings ▸ Pages ▸ branch `gh-pages`, folder `/`.
- **Binary** — the DMG is a GitHub Release asset on tag `v<version>`. The appcast
  enclosure URL is built from that, so the asset name must stay
  `vibebuddy-mac-v<version>.dmg`.

Publishing is deliberately *not* automated: the script prints the `gh release create`
and `gh-pages` commands and stops. Run them when you mean to ship.

## Per release

1. Bump `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in
   `VibeBuddyMacApp/project.yml`. Sparkle compares `CURRENT_PROJECT_VERSION`
   (`CFBundleVersion`), so it **must** increase or installed copies will not see the
   update.
2. Write `docs/release-notes-<version>.md`.
3. `tools/release-mac.sh`
4. Run the two publish commands it prints.
5. Check for Updates… from an older installed copy, and confirm it offers and
   installs the new one.

Sparkle docs: <https://sparkle-project.org/documentation/>.
