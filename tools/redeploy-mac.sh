#!/usr/bin/env bash
# Build, stably re-sign, and redeploy the vibebuddy Mac app to /Applications.
#
# Why re-sign: the build signs ad-hoc ("-"), whose cdhash changes every rebuild.
# macOS keys Keychain ACLs and TCC grants to that cdhash, so an ad-hoc rebuild
# re-prompts for the keychain password on every secret read. Signing the built
# bundle with a STABLE local identity (Apple Development / Developer ID) makes
# macOS track the grant by the cert's designated requirement instead, so one
# "Always Allow" survives every future rebuild. Mirrors open-vibe-island's
# launch-dev-app.sh approach. No Apple Developer Program steps beyond having a
# codesigning cert in your login keychain (you already do).
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_PROJ="$REPO/VibeBuddyMacApp"
BUILD_PROD="$APP_PROJ/build/Build/Products/Release/VibeBuddyMacApp.app"
DEST="/Applications/VibeBuddyMacApp.app"

echo "▸ regenerating + building Release…"
( cd "$APP_PROJ" && xcodegen generate >/dev/null \
  && xcodebuild -project VibeBuddyMacApp.xcodeproj -scheme VibeBuddyMacApp \
       -configuration Release -derivedDataPath build build \
       -quiet )

# Prefer a Developer ID, else any Apple Development cert; fall back to ad-hoc.
pick_identity() {
  security find-identity -p codesigning -v 2>/dev/null \
    | grep -Eo '[0-9A-F]{40} "(Developer ID Application|Apple Development)[^"]*"' \
    | sort -r | head -1 | awk '{print $1}'
}
IDENTITY="$(pick_identity || true)"

if [[ -n "${IDENTITY:-}" ]]; then
  echo "▸ re-signing with stable identity ${IDENTITY}…"
  codesign --force --deep --sign "$IDENTITY" "$BUILD_PROD"
else
  echo "⚠ no stable codesigning identity found — staying ad-hoc."
  echo "  The keychain will keep re-prompting after each rebuild."
fi

echo "▸ verifying signature…"
codesign -dvv "$BUILD_PROD" 2>&1 | grep -iE "Authority|TeamIdentifier|Signature=" || true

echo "▸ deploying to ${DEST} and relaunching…"
pkill -9 -f VibeBuddyMacApp 2>/dev/null || true
sleep 1
ditto "$BUILD_PROD" "$DEST"
open "$DEST"
sleep 2
pgrep -fl VibeBuddyMacApp | head -1 || echo "(not running?)"
echo "✓ done. On the next keychain prompt, click \"Always Allow\" once — it now sticks across rebuilds."
