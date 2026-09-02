#!/usr/bin/env bash
# Archive and export the vibebuddy iPhone app for App Store Connect / TestFlight.
#
#   tools/archive-ios.sh                       # sign with the Apple ID signed into Xcode
#   tools/archive-ios.sh --api-key ~/keys/AuthKey_ABC1234567.p8 --issuer <uuid>
#
# Produces an .ipa. It does NOT upload — uploading puts a build in front of Apple
# and of your testers, so the last step stays yours. The command is printed at the
# end. See docs/app-store-submission-checklist.md for everything around it.
#
# The API key is passed to xcodebuild by *path*; this script never reads its
# contents. Its only use is letting Xcode create the distribution certificate and
# provisioning profiles your account is missing (-allowProvisioningUpdates).
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_PROJ="$REPO/VibeBuddyApp"
BUILD="$APP_PROJ/build"                 # matches .gitignore's build/ — never committed
SCHEME="VibeBuddyApp"
BUNDLE_ID="com.vibebuddy.app"
WIDGET_BUNDLE_ID="com.vibebuddy.app.widget"

API_KEY=""
KEY_ID=""
ISSUER=""
SKIP_EXPORT=0

die()  { printf '\n\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
step() { printf '\n\033[1m▸ %s\033[0m\n' "$*"; }
note() { printf '  %s\n' "$*"; }

needs_you() {
  printf '\n\033[33m⏸  This step needs you — I cannot do it for you.\033[0m\n' >&2
  printf '\033[33m   %s\033[0m\n\n' "$1" >&2
  shift
  for line in "$@"; do printf '      %s\n' "$line" >&2; done
  printf '\n'
  exit 2
}

usage() {
  sed -n '2,12p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  cat <<'USAGE'
Options:
  --api-key <path>   App Store Connect API key (.p8) for -allowProvisioningUpdates.
                     Omit to use the Apple ID signed into Xcode instead.
  --key-id <id>      Key ID. Default: read from the AuthKey_<id>.p8 filename.
  --issuer <uuid>    Issuer ID, from App Store Connect ▸ Users and Access ▸
                     Integrations ▸ Team Keys. Required with --api-key.
  --skip-export      Stop after the archive (useful when signing is not sorted yet).
  -h, --help         This text
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --api-key)     API_KEY="$2"; shift 2 ;;
    --key-id)      KEY_ID="$2"; shift 2 ;;
    --issuer)      ISSUER="$2"; shift 2 ;;
    --skip-export) SKIP_EXPORT=1; shift ;;
    -h|--help)     usage; exit 0 ;;
    *) die "unknown option: $1 (try --help)" ;;
  esac
done

# ── Preflight ────────────────────────────────────────────────────────────────

step "preflight"

TEAM_ID="$(sed -n 's/^ *DEVELOPMENT_TEAM: *\([A-Z0-9]\{10\}\).*/\1/p' "$APP_PROJ/project.yml" | head -1)"
[[ -n "$TEAM_ID" ]] || die "no DEVELOPMENT_TEAM in $APP_PROJ/project.yml"
note "team: $TEAM_ID"

AUTH_ARGS=()
if [[ -n "$API_KEY" ]]; then
  [[ -f "$API_KEY" ]] || die "no such API key file: $API_KEY"
  [[ -n "$KEY_ID" ]] || KEY_ID="$(basename "$API_KEY" | sed -n 's/^AuthKey_\([A-Za-z0-9]*\)\.p8$/\1/p')"
  [[ -n "$KEY_ID" ]] || die "could not read the Key ID from the filename — pass --key-id"
  [[ -n "$ISSUER" ]] || die "--issuer is required with --api-key"
  AUTH_ARGS=(-authenticationKeyPath "$(cd "$(dirname "$API_KEY")" && pwd)/$(basename "$API_KEY")"
             -authenticationKeyID "$KEY_ID"
             -authenticationKeyIssuerID "$ISSUER")
  note "signing authority: App Store Connect API key $KEY_ID"
else
  note "signing authority: the Apple ID signed into Xcode"
fi

# Deliberately no check for a local Apple Distribution certificate. With automatic
# signing the archive is signed for *development* and `-exportArchive` re-signs for
# distribution — often with a cloud-managed certificate whose private key stays at
# Apple, so a correct setup can have no distribution identity in the keychain at
# all. The signature that matters is on the exported .ipa, and it is checked there.

# ── Configuration audit ──────────────────────────────────────────────────────
# The Release settings that are invisible until App Store Connect rejects the
# upload. Checked against project.yml before the build, so a fix is one edit away.

step "auditing the Release configuration"

check() { # check <label> <expected> <actual>
  if [[ "$2" == "$3" ]]; then note "$1: $3"
  else FAILED+=("$1: expected \"$2\", found \"$3\""); fi
}
FAILED=()

VERSION="$(sed -n 's/^ *MARKETING_VERSION: *"\([^"]*\)".*/\1/p' "$APP_PROJ/project.yml" | head -1)"
BUILD_NO="$(sed -n 's/^ *CURRENT_PROJECT_VERSION: *"\([^"]*\)".*/\1/p' "$APP_PROJ/project.yml" | head -1)"
note "version: $VERSION (build $BUILD_NO)"
[[ "$BUILD_NO" =~ ^[0-9]+$ ]] || FAILED+=("CURRENT_PROJECT_VERSION must be an integer, found \"$BUILD_NO\"")

APS="$(/usr/libexec/PlistBuddy -c 'Print :aps-environment' "$APP_PROJ/VibeBuddyApp.entitlements" 2>/dev/null || echo MISSING)"
check "aps-environment (Release)" "production" "$APS"

ENC="$(sed -n 's/^ *ITSAppUsesNonExemptEncryption: *\(.*\)$/\1/p' "$APP_PROJ/project.yml" | head -1)"
check "ITSAppUsesNonExemptEncryption" "false" "$ENC"

APP_GROUP="$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.application-groups:0' "$APP_PROJ/VibeBuddyApp.entitlements" 2>/dev/null || echo MISSING)"
WIDGET_GROUP="$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.application-groups:0' "$APP_PROJ/Widget/VibeBuddyWidget.entitlements" 2>/dev/null || echo MISSING)"
[[ "$APP_GROUP" != MISSING ]] || FAILED+=("the app declares no App Group, but the widget reads shared state through one")
check "app group (widget matches app)" "$APP_GROUP" "$WIDGET_GROUP"

# The widget's bundle id must extend the app's, or the upload is rejected with a
# nested-bundle error that names neither of them.
if sed -n 's/^ *PRODUCT_BUNDLE_IDENTIFIER: *\(.*\)$/\1/p' "$APP_PROJ/project.yml" | grep -qx "$WIDGET_BUNDLE_ID"; then
  note "widget bundle id: $WIDGET_BUNDLE_ID"
else
  FAILED+=("no target declares PRODUCT_BUNDLE_IDENTIFIER $WIDGET_BUNDLE_ID")
fi
[[ "$WIDGET_BUNDLE_ID" == "$BUNDLE_ID."* ]] || FAILED+=("widget bundle id must start with \"$BUNDLE_ID.\"")

ICON="$APP_PROJ/Sources/Assets.xcassets/AppIcon.appiconset/icon_1024.png"
if [[ -f "$ICON" ]]; then
  DIMS="$(sips -g pixelWidth -g pixelHeight "$ICON" 2>/dev/null | awk '/pixel/ {print $2}' | paste -sd x -)"
  check "1024 app icon" "1024x1024" "$DIMS"
  # A marketing icon with an alpha channel is rejected on upload, every time.
  if sips -g hasAlpha "$ICON" 2>/dev/null | grep -q 'hasAlpha: yes'; then
    FAILED+=("the 1024 app icon has an alpha channel — App Store Connect rejects that")
  fi
else
  FAILED+=("missing $ICON")
fi

if ((${#FAILED[@]})); then
  printf '\n\033[31m✗ Release configuration problems:\033[0m\n' >&2
  printf '    %s\n' "${FAILED[@]}" >&2
  exit 1
fi

# ── Archive ──────────────────────────────────────────────────────────────────

ARCHIVE="$BUILD/VibeBuddyApp-$VERSION-$BUILD_NO.xcarchive"
EXPORT_DIR="$BUILD/export"

step "archiving $SCHEME $VERSION ($BUILD_NO)"
( cd "$APP_PROJ" && xcodegen generate >/dev/null )
rm -rf "$ARCHIVE"
xcodebuild archive \
  -project "$APP_PROJ/VibeBuddyApp.xcodeproj" \
  -scheme "$SCHEME" \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath "$ARCHIVE" \
  -derivedDataPath "$BUILD/DerivedData" \
  -allowProvisioningUpdates \
  "${AUTH_ARGS[@]}" \
  -quiet
[[ -d "$ARCHIVE" ]] || die "no archive at $ARCHIVE"

# ── What actually ended up in the archive ────────────────────────────────────
# project.yml says what we asked for; this says what we got. They diverge when a
# build setting is overridden somewhere Xcode does not surface. Signing is *not*
# checked here — see the note in preflight; it is checked on the .ipa below.

step "verifying the archive"
ARCHIVED_APP="$ARCHIVE/Products/Applications/VibeBuddyApp.app"
[[ -d "$ARCHIVED_APP" ]] || die "no app inside the archive"
note "CFBundleShortVersionString: $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ARCHIVED_APP/Info.plist")"
note "CFBundleVersion:            $(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$ARCHIVED_APP/Info.plist")"
note "bundle id:                  $(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$ARCHIVED_APP/Info.plist")"

WIDGET_IN_ARCHIVE="$ARCHIVED_APP/PlugIns/VibeBuddyWidget.appex"
[[ -d "$WIDGET_IN_ARCHIVE" ]] || die "the widget extension is missing from the archive"
note "widget:                     $(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$WIDGET_IN_ARCHIVE/Info.plist")"

if (( SKIP_EXPORT )); then
  step "export skipped (--skip-export)"
  note "archive: $ARCHIVE"
  exit 0
fi

# ── Export ───────────────────────────────────────────────────────────────────

step "exporting for App Store Connect"
OPTS="$BUILD/ExportOptions.plist"
cat > "$OPTS" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>app-store-connect</string>
    <key>teamID</key>
    <string>$TEAM_ID</string>
    <key>uploadSymbols</key>
    <true/>
    <!-- We set the build number in project.yml; Xcode must not pick its own. -->
    <key>manageAppVersionAndBuildNumber</key>
    <false/>
    <key>signingStyle</key>
    <string>automatic</string>
    <key>destination</key>
    <string>export</string>
</dict>
</plist>
PLIST

rm -rf "$EXPORT_DIR"
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportOptionsPlist "$OPTS" \
  -exportPath "$EXPORT_DIR" \
  -allowProvisioningUpdates \
  "${AUTH_ARGS[@]}"

IPA="$(find "$EXPORT_DIR" -name '*.ipa' -maxdepth 1 -print -quit)"
[[ -n "$IPA" ]] || die "export produced no .ipa in $EXPORT_DIR"

# ── What is actually inside the .ipa ─────────────────────────────────────────
# This is the artifact App Store Connect judges, and the first point at which the
# distribution signature exists. Everything checked here has the same failure
# mode: the upload is accepted, and something is silently broken for testers.

step "verifying the exported .ipa"
UNPACKED="$(mktemp -d)"
trap 'rm -rf "$UNPACKED"' EXIT
unzip -q "$IPA" -d "$UNPACKED"
SHIPPED="$(find "$UNPACKED/Payload" -maxdepth 1 -name '*.app' -print -quit)"
[[ -n "$SHIPPED" ]] || die "no .app inside $IPA"

authority() { codesign -dvv "$1" 2>&1 | sed -n 's/^Authority=//p' | head -1; }
entitlement() { codesign -d --entitlements - --xml "$1" 2>/dev/null | plutil -extract "$2" raw -o - - 2>/dev/null || echo MISSING; }

APP_AUTH="$(authority "$SHIPPED")"
note "signed by: $APP_AUTH"
[[ "$APP_AUTH" == Apple\ Distribution* || "$APP_AUTH" == iPhone\ Distribution* ]] \
  || die "the exported app is signed by \"$APP_AUTH\", not an Apple Distribution certificate — App Store Connect rejects that"

# The one that cannot be caught later: production tokens with a sandbox-registered
# app means push simply never arrives, and nothing in the app explains why.
SHIPPED_APS="$(entitlement "$SHIPPED" aps-environment)"
[[ "$SHIPPED_APS" == "production" ]] \
  || die "the exported app has aps-environment=\"$SHIPPED_APS\", not \"production\" — Apple would issue production push tokens to an app registered for sandbox"
note "aps-environment: production"

[[ "$(entitlement "$SHIPPED" get-task-allow)" == "false" ]] \
  || die "get-task-allow is not false — that is a development signature, not a distribution one"
note "get-task-allow: false"

SHIPPED_WIDGET="$SHIPPED/PlugIns/VibeBuddyWidget.appex"
[[ -d "$SHIPPED_WIDGET" ]] || die "the widget extension did not survive the export"
WIDGET_AUTH="$(authority "$SHIPPED_WIDGET")"
[[ "$WIDGET_AUTH" == Apple\ Distribution* || "$WIDGET_AUTH" == iPhone\ Distribution* ]] \
  || die "the widget is signed by \"$WIDGET_AUTH\", not an Apple Distribution certificate"
note "widget: $(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$SHIPPED_WIDGET/Info.plist"), distribution-signed"

step "done — $SCHEME $VERSION (build $BUILD_NO)"
note "archive: $ARCHIVE"
note "ipa:     $IPA"
note "size:    $(du -h "$IPA" | cut -f1)"

cat <<UPLOAD

  Uploading is deliberately manual — it puts a build in front of Apple and your
  testers. When you mean to, easiest first:

    Xcode ▸ Window ▸ Organizer ▸ select this archive ▸ Distribute App

  or from the command line, with the API key copied to
  ~/.appstoreconnect/private_keys/AuthKey_<key-id>.p8 where altool looks for it:

    xcrun altool --upload-app -f "$IPA" -t ios \\
        --apiKey <key-id> --apiIssuer <issuer-uuid>

  Either way the build needs a few minutes of processing before it shows up
  under TestFlight.

  Everything you must paste into the App Store Connect web forms, in field order:
  docs/app-store-paste-sheet.md

UPLOAD
