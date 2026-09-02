#!/usr/bin/env bash
# Build, Developer-ID sign, notarize, staple, package (DMG) and appcast the
# vibebuddy Mac app for direct distribution (Sparkle; not the Mac App Store).
#
# The three things this script cannot do for you — because they need your
# identity or a key you must own — are checked up front and explained with the
# exact command to run. See docs/sparkle-setup.md for the whole runbook.
#
#   tools/release-mac.sh                 # full release: build → notarize → DMG → appcast
#   tools/release-mac.sh --skip-notarize # dry run: everything except the Apple round trips
#
# Nothing here touches /Applications or :9876 — that is tools/redeploy-mac.sh.
# Nothing here pushes, tags, or creates a GitHub Release; the final publish steps
# are printed at the end for a human to run.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_PROJ="$REPO/VibeBuddyMacApp"
DERIVED="$APP_PROJ/build"
BUILT_APP="$DERIVED/Build/Products/Release/VibeBuddyMacApp.app"
ENTITLEMENTS="$REPO/tools/vibebuddy-mac.entitlements"
OUT_DIR="$REPO/dist"

NOTARY_PROFILE="vibebuddy-notary"
SPARKLE_ACCOUNT="ed25519"          # keychain account holding the EdDSA private key
IDENTITY=""                        # default: the Developer ID Application cert in the keychain
SKIP_NOTARIZE=0
DOWNLOAD_URL_PREFIX=""             # default: this repo's GitHub Release assets for the tag
PRODUCT_LINK="https://github.com/semantic-craft/iOS-vibebuddy"

die()  { printf '\n\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
step() { printf '\n\033[1m▸ %s\033[0m\n' "$*"; }
note() { printf '  %s\n' "$*"; }

# A blocker only you can clear: print what to run, then stop.
needs_you() {
  printf '\n\033[33m⏸  This step needs you — I cannot do it for you.\033[0m\n' >&2
  printf '\033[33m   %s\033[0m\n' "$1" >&2
  shift
  printf '\n' >&2
  for line in "$@"; do printf '      %s\n' "$line" >&2; done
  printf '\n   Then re-run: tools/release-mac.sh %s\n\n' "$ORIGINAL_ARGS" >&2
  exit 2
}

usage() {
  sed -n '2,14p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  cat <<'USAGE'
Options:
  --identity <name|sha1>   Developer ID Application identity (default: the one in your keychain)
  --notary-profile <name>  notarytool keychain profile (default: vibebuddy-notary)
  --sparkle-account <name> Keychain account for the Sparkle EdDSA key (default: ed25519)
  --download-url-prefix <url>
                           Where the DMG will be downloadable from; becomes the appcast
                           enclosure URL (default: this repo's GitHub Release for v<version>)
  --skip-notarize          Build, sign, package and appcast without contacting Apple.
                           The DMG is real but Gatekeeper will reject it — dry run only.
  -h, --help               This text
USAGE
}

ORIGINAL_ARGS="$*"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --identity)            IDENTITY="$2"; shift 2 ;;
    --notary-profile)      NOTARY_PROFILE="$2"; shift 2 ;;
    --sparkle-account)     SPARKLE_ACCOUNT="$2"; shift 2 ;;
    --download-url-prefix) DOWNLOAD_URL_PREFIX="$2"; shift 2 ;;
    --skip-notarize)       SKIP_NOTARIZE=1; shift ;;
    -h|--help)             usage; exit 0 ;;
    *) die "unknown option: $1 (try --help)" ;;
  esac
done

# ── Preflight ────────────────────────────────────────────────────────────────
# Everything that can block the release is checked before the first long build.

step "preflight"

[[ -f "$ENTITLEMENTS" ]] || die "missing $ENTITLEMENTS"

# 1. Developer ID Application certificate.
if [[ -z "$IDENTITY" ]]; then
  IDENTITY="$(security find-identity -p codesigning -v 2>/dev/null \
    | grep -o '"Developer ID Application[^"]*"' | head -1 | tr -d '"')" || true
fi
if [[ -z "$IDENTITY" ]]; then
  needs_you "No \"Developer ID Application\" certificate in your keychain." \
    "Xcode ▸ Settings ▸ Accounts ▸ (your Apple ID) ▸ Manage Certificates ▸ + ▸" \
    "  \"Developer ID Application\".  Requires a paid Apple Developer Program membership." \
    "Verify with:  security find-identity -p codesigning -v"
fi
note "signing identity: $IDENTITY"

TEAM_ID="$(sed -n 's/.*(\([A-Z0-9]\{10\}\)).*/\1/p' <<<"$IDENTITY")"
[[ -n "$TEAM_ID" ]] || die "could not read the Team ID out of the identity name: $IDENTITY"
note "team: $TEAM_ID"

# 2. Sparkle EdDSA private key, and that it matches the public key we ship.
EXPECTED_PUBKEY="$(sed -n 's/^ *SUPublicEDKey: *"\([^"]*\)".*/\1/p' "$APP_PROJ/project.yml")"
[[ -n "$EXPECTED_PUBKEY" ]] || die "SUPublicEDKey not found in $APP_PROJ/project.yml"
KEYCHAIN_PUBKEY="$(security find-generic-password -s 'https://sparkle-project.org' \
  -a "$SPARKLE_ACCOUNT" 2>/dev/null \
  | sed -n 's/.*"icmt"<blob>=.*key is:.012.012\(.*\)"$/\1/p')" || true
if [[ -z "$KEYCHAIN_PUBKEY" ]]; then
  needs_you "No Sparkle signing key in your login Keychain (account \"$SPARKLE_ACCOUNT\")." \
    "Run Sparkle's generate_keys once — the PRIVATE key goes into your Keychain," \
    "and I must never see it:" \
    "" \
    "  \"\$(find \"$DERIVED/SourcePackages/artifacts\" -name generate_keys | head -1)\"" \
    "" \
    "Then paste the printed public key into VibeBuddyMacApp/project.yml → SUPublicEDKey."
fi
if [[ "$KEYCHAIN_PUBKEY" != "$EXPECTED_PUBKEY" ]]; then
  die "Sparkle key mismatch — updates signed now could not be verified by the shipped app.
     project.yml SUPublicEDKey: $EXPECTED_PUBKEY
     keychain \"$SPARKLE_ACCOUNT\":  $KEYCHAIN_PUBKEY"
fi
note "sparkle key: $EXPECTED_PUBKEY (keychain account \"$SPARKLE_ACCOUNT\")"

# 3. notarytool credentials.
if (( ! SKIP_NOTARIZE )); then
  if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
    needs_you "No notarytool keychain profile named \"$NOTARY_PROFILE\"." \
      "Create an App Store Connect API key (Users and Access ▸ Integrations ▸ Team Keys," \
      "role Developer), download the .p8, then run this yourself and type the key in —" \
      "I must not handle it:" \
      "" \
      "  xcrun notarytool store-credentials $NOTARY_PROFILE \\" \
      "      --key /path/to/AuthKey_XXXXXXXXXX.p8 --key-id XXXXXXXXXX --issuer <issuer-uuid>" \
      "" \
      "Or, with an app-specific password instead of an API key:" \
      "  xcrun notarytool store-credentials $NOTARY_PROFILE \\" \
      "      --apple-id <your-apple-id> --team-id $TEAM_ID --password <app-specific-password>"
  fi
  note "notary profile: $NOTARY_PROFILE"
else
  note "notary profile: skipped (--skip-notarize)"
fi

# ── Build ────────────────────────────────────────────────────────────────────
# Unsigned: this script signs everything itself, in one visible inside-out pass,
# because Xcode does not sign the helpers nested inside Sparkle.framework.

step "regenerating + building Release"
( cd "$APP_PROJ" && xcodegen generate >/dev/null \
  && xcodebuild -project VibeBuddyMacApp.xcodeproj -scheme VibeBuddyMacApp \
       -configuration Release -derivedDataPath build build \
       CODE_SIGNING_ALLOWED=NO -quiet )
[[ -d "$BUILT_APP" ]] || die "build produced no app at $BUILT_APP"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$BUILT_APP/Contents/Info.plist")"
BUILD_NO="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$BUILT_APP/Contents/Info.plist")"
note "built vibebuddy $VERSION (build $BUILD_NO)"

BASENAME="vibebuddy-mac-v$VERSION"          # matches the v1.0 asset naming
DMG="$OUT_DIR/$BASENAME.dmg"
: "${DOWNLOAD_URL_PREFIX:=$PRODUCT_LINK/releases/download/v$VERSION/}"

# ── Sign ─────────────────────────────────────────────────────────────────────
# Inside out: every nested code object first, the app last, because signing a
# nested bundle invalidates the seal of everything containing it.
#
# The reason this is not left to Xcode: Xcode signs Sparkle.framework but not the
# Updater.app, Autoupdate and XPC services *inside* it, which stay ad-hoc from
# Sparkle's own binary artifact. Notarization rejects an ad-hoc signature outright.

sign() { codesign --force --options runtime --timestamp --sign "$IDENTITY" "$@"; }

step "signing inside out"
SPARKLE="$BUILT_APP/Contents/Frameworks/Sparkle.framework"
[[ -d "$SPARKLE" ]] || die "no Sparkle.framework in the built app — the updater is a hard dependency"
SPARKLE_V="$(find "$SPARKLE/Versions" -mindepth 1 -maxdepth 1 -type d -print -quit)"
[[ -n "$SPARKLE_V" ]] || die "no versioned directory inside $SPARKLE"
while IFS= read -r obj; do
  note "$(basename "$obj")"; sign "$obj"
done < <(find "$SPARKLE_V" -depth \( -name '*.xpc' -o -name '*.app' \))
note "Autoupdate";        sign "$SPARKLE_V/Autoupdate"
note "Sparkle.framework"; sign "$SPARKLE"
for lib in "$BUILT_APP/Contents/Frameworks"/*.dylib; do
  [[ -e "$lib" ]] || continue
  note "$(basename "$lib")"; sign "$lib"
done
note "VibeBuddyMacApp.app"
sign --entitlements "$ENTITLEMENTS" "$BUILT_APP"

# ── Verify ───────────────────────────────────────────────────────────────────
# Notarization rejects the whole submission over one unsigned, un-timestamped or
# un-hardened binary. Cheaper to find that here than after a round trip to Apple.

step "verifying the signature"
codesign --verify --deep --strict "$BUILT_APP" && note "codesign --verify --deep --strict: ok"
# `file` names each slice of a universal binary as "<path> (for architecture x)";
# those are not paths, so strip the suffix and dedupe before asking codesign.
BAD="$(find "$BUILT_APP" -type f -perm -u+x -print0 \
  | xargs -0 file --mime-type 2>/dev/null \
  | grep 'application/x-mach-binary' \
  | sed -e 's/ (for architecture [^)]*)//' -e 's/:.*//' \
  | sort -u \
  | while IFS= read -r bin; do
      [[ -f "$bin" ]] || continue
      out="$(codesign -dvv "$bin" 2>&1 </dev/null)"
      grep -q 'flags=.*runtime'                  <<<"$out" || { echo "not hardened: $bin"; continue; }
      grep -q 'Authority=Developer ID Application' <<<"$out" || { echo "not Developer ID: $bin"; continue; }
      grep -q '^Timestamp='                      <<<"$out" || echo "no secure timestamp: $bin"
    done)"
[[ -z "$BAD" ]] || die "notarization would reject these:
$BAD"
note "every Mach-O: Developer ID, hardened runtime, secure timestamp"
codesign -dvv "$BUILT_APP" 2>&1 | grep -E 'Authority=Developer ID Application|TeamIdentifier|flags=' || true

# ── Notarize the app, then staple it ─────────────────────────────────────────
# Two round trips on purpose: stapling the .app as well as the .dmg is what lets
# a first launch succeed offline, after the user has dragged it out of the image.

mkdir -p "$OUT_DIR"
if (( SKIP_NOTARIZE )); then
  step "notarizing the app — SKIPPED (--skip-notarize)"
else
  step "notarizing the app (this waits on Apple; minutes, not seconds)"
  APP_ZIP="$OUT_DIR/$BASENAME-app.zip"
  ditto -c -k --keepParent "$BUILT_APP" "$APP_ZIP"
  xcrun notarytool submit "$APP_ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
  rm -f "$APP_ZIP"
  xcrun stapler staple "$BUILT_APP"
fi

# ── DMG ──────────────────────────────────────────────────────────────────────

step "packaging $DMG"
STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT
ditto "$BUILT_APP" "$STAGING/VibeBuddyMacApp.app"
ln -s /Applications "$STAGING/Applications"
rm -f "$DMG"
hdiutil create -volname "vibebuddy $VERSION" -srcfolder "$STAGING" \
  -ov -format UDZO -quiet "$DMG"
codesign --force --timestamp --sign "$IDENTITY" "$DMG"

if (( SKIP_NOTARIZE )); then
  step "notarizing + stapling the DMG — SKIPPED (--skip-notarize)"
else
  step "notarizing the DMG (second Apple round trip)"
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
fi

# ── Gatekeeper assessment ────────────────────────────────────────────────────

step "Gatekeeper assessment"
if (( SKIP_NOTARIZE )); then
  spctl --assess -vv --type exec "$BUILT_APP" 2>&1 || true
  note "rejection above is expected on a dry run — the build is Developer-ID signed but not notarized"
else
  xcrun stapler validate "$DMG"
  spctl --assess -vv --type exec "$BUILT_APP"
  spctl --assess -vv --type open --context context:primary-signature "$DMG"
fi

# ── Appcast ──────────────────────────────────────────────────────────────────
# generate_appcast runs sign_update over each archive in dist/, so the EdDSA
# signature and length in the feed are never hand-written.

step "generating the signed appcast"
GENERATE_APPCAST="$(find "$DERIVED/SourcePackages/artifacts" -name generate_appcast -type f 2>/dev/null | head -1)"
[[ -n "$GENERATE_APPCAST" ]] || die "generate_appcast not found under $DERIVED/SourcePackages/artifacts"

RELEASE_NOTES="$REPO/docs/release-notes-$VERSION.md"
if [[ -f "$RELEASE_NOTES" ]]; then
  # Same basename as the archive ⇒ generate_appcast links the feed entry at it.
  # That link is served from gh-pages, so this .md is published next to appcast.xml.
  cp "$RELEASE_NOTES" "$OUT_DIR/$BASENAME.md"
  note "release notes: docs/release-notes-$VERSION.md"
else
  note "no docs/release-notes-$VERSION.md — the feed entry will have no description"
fi

"$GENERATE_APPCAST" \
  --account "$SPARKLE_ACCOUNT" \
  --download-url-prefix "$DOWNLOAD_URL_PREFIX" \
  --link "$PRODUCT_LINK" \
  "$OUT_DIR"

# ── Summary ──────────────────────────────────────────────────────────────────

step "done — vibebuddy $VERSION (build $BUILD_NO)"
note "DMG:     $DMG"
note "appcast: $OUT_DIR/appcast.xml"
note "feed:    $(sed -n 's/^ *SUFeedURL: *"\([^"]*\)".*/\1/p' "$APP_PROJ/project.yml")"
note "enclosure URL prefix: $DOWNLOAD_URL_PREFIX"
if (( SKIP_NOTARIZE )); then
  printf '\n\033[33m  Dry run: not notarized, not stapled. Do NOT publish this DMG.\033[0m\n\n'
  exit 0
fi
cat <<PUBLISH

  Publishing is deliberately manual — run these yourself when you mean it:

    gh release create v$VERSION "$DMG" \\
      --repo semantic-craft/iOS-vibebuddy \\
      --title "vibebuddy $VERSION — macOS" \\
      --notes-file docs/release-notes-$VERSION.md

    # feed + release notes on the gh-pages branch, served at the SUFeedURL above.
    # Both files: the feed's <sparkle:releaseNotesLink> points at the .md next to it.
    git worktree add /tmp/vibebuddy-pages gh-pages   # or: git checkout --orphan gh-pages
    cp "$OUT_DIR/appcast.xml" "$OUT_DIR/$BASENAME.md" /tmp/vibebuddy-pages/
    ( cd /tmp/vibebuddy-pages && git add appcast.xml "$BASENAME.md" \\
        && git commit -m "release: appcast for $VERSION" && git push origin gh-pages )

  The asset name must stay "$BASENAME.dmg" — the appcast enclosure URL points at it.
  GitHub Pages must be enabled for the repo (Settings ▸ Pages ▸ branch gh-pages, / root).

PUBLISH
