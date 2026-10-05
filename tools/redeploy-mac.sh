#!/usr/bin/env bash
# Prepare a signed local build, then explicitly install it after peer coordination.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_PROJ="$REPO/VibeBuddyMacApp"
DEST="/Applications/VibeBuddyMacApp.app"
INSTALL_JSON=0
args=()
for arg in "$@"; do
  if [[ "$arg" == --json ]]; then INSTALL_JSON=1; else args+=("$arg"); fi
done
set -- ${args[@]+"${args[@]}"}
invalid_arguments() {
  if (( INSTALL_JSON )); then
    echo '{"schema_version":1,"status":"error","exit_code":2,"error":{"code":"invalid_arguments","message":"Use --plan/--dry-run ABSOLUTE_APP [--peer-check-complete], or --install ABSOLUTE_APP --peer-check-complete; --json supports these operations only."}}'
  else usage >&2; fi
  exit 2
}
usage() {
  cat <<'USAGE'
Usage:
  tools/redeploy-mac.sh --prepare
  tools/redeploy-mac.sh --install /absolute/prepared/VibeBuddyMacApp.app --peer-check-complete
  tools/redeploy-mac.sh --plan /absolute/prepared/VibeBuddyMacApp.app [--peer-check-complete]

--plan (alias --dry-run) emits JSON without writing, signing, stopping or launching.
It discloses process/port reads and unknown peer ownership; exit 1 means blocked.
--json on --install emits one receipt on stdout; diagnostics go to stderr.

--prepare builds/signs/verifies an isolated candidate; it does not install or launch.
--install requires prior authorization and a fresh shared-device/peer check:
  docs/sparkle-setup.md, "The installed app is shared".
--peer-check-complete attests that this check was completed AFTER preparation.
It is not authorization, and does not prove hardware is idle. Installs serialize
across worktrees; failed copies/signatures leave the old app alone, failed startup
restores it. A previous.app backup is retained beside the installed application.
USAGE
}
case "${1:---help}" in
  -h|--help) usage; exit 0 ;;
  --prepare) [[ $# == 1 && "$INSTALL_JSON" == 0 ]] || invalid_arguments ;;
  --plan|--dry-run)
    [[ $# -ge 2 && $# -le 3 && "$2" == /* && ( $# == 2 || "$3" == --peer-check-complete ) ]] || invalid_arguments
    checked=0
    [[ $# == 2 ]] || checked=1
    exec python3 "$REPO/tools/install-contract.py" plan "$2" "$DEST" "$checked" ;;
  --install)
    [[ $# == 3 && "$3" == --peer-check-complete && "$2" == /* ]] || invalid_arguments
    source "$REPO/tools/lib/mac-app-runtime.sh"
    source "$REPO/tools/lib/install-mac-app.sh"
    install_mac_app "$2" "$DEST"
    exit ;;
  *) invalid_arguments ;;
esac

mkdir -p "$REPO/.scratch/deploy"
PREPARED="$(mktemp -d "$REPO/.scratch/deploy/candidate.XXXXXX")"
BUILD_PROD="$PREPARED/build/Build/Products/Release/VibeBuddyMacApp.app"
python3 "$REPO/tools/check.py" --source-state > "$PREPARED/source-before.json"
echo "▸ regenerating + building Release…"
( cd "$APP_PROJ" && xcodegen generate >/dev/null
  xcodebuild -project VibeBuddyMacApp.xcodeproj -scheme VibeBuddyMacApp \
    -configuration Release -derivedDataPath "$PREPARED/build" build -quiet )
# Prefer a Developer ID, else any Apple Development cert; fall back to ad-hoc.
pick_identity() {
  local identities type hash
  identities="$(security find-identity -p codesigning -v 2>/dev/null || true)"
  for type in "Developer ID Application" "Apple Development"; do
    hash="$(printf '%s\n' "$identities" \
      | grep -Eo "[0-9A-F]{40} \"${type}[^\"]*\"" \
      | head -1 | awk '{print $1}')" || hash=""
    if [[ -n "$hash" ]]; then
      printf '%s\n' "$hash"
      return 0
    fi
  done
  return 0
}
IDENTITY="$(pick_identity || true)"

if [[ -n "${IDENTITY:-}" ]]; then
  echo "▸ re-signing with stable identity ${IDENTITY}…"
  codesign --force --deep --sign "$IDENTITY" "$BUILD_PROD"
  # iCloud cues (ADR-0013 D) only with a profile that allows them for this
  # certificate; without one the app is signed exactly as before.
  # Used by the sourced CloudKit signing helper.
  # shellcheck disable=SC2034
  CLOUDKIT_BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$BUILD_PROD/Contents/Info.plist")"
  # shellcheck source=tools/mac-cloudkit-signing.sh
  source "$REPO/tools/mac-cloudkit-signing.sh"
  CK_PROFILE="$(cloudkit_profile_for "$IDENTITY")"
  if [[ -n "$CK_PROFILE" ]]; then
    CK_ENT="$PREPARED/entitlements.plist"
    cp "$CK_PROFILE" "$BUILD_PROD/Contents/embedded.provisionprofile"
    CK_ENV="$(cloudkit_entitlements "$CK_PROFILE" "$REPO/tools/vibebuddy-mac.entitlements" "$CK_ENT")"
    codesign --force --sign "$IDENTITY" --entitlements "$CK_ENT" "$BUILD_PROD"
    rm -f "$CK_ENT"
    echo "▸ iCloud cues: on (${CK_ENV})"
  else
    echo "▸ iCloud cues: off — no CloudKit profile for this certificate (tools/fetch-mac-cloudkit-profiles.sh)"
  fi
else
  echo "⚠ no stable codesigning identity found — staying ad-hoc."
  echo "  The keychain will keep re-prompting after each rebuild."
fi

source "$REPO/tools/lib/mac-app-runtime.sh"
verify_app "$BUILD_PROD"
ditto "$BUILD_PROD" "$PREPARED/VibeBuddyMacApp.app"
verify_app "$PREPARED/VibeBuddyMacApp.app"
/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$BUILD_PROD/Contents/Info.plist" > "$PREPARED/version.txt"
/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$BUILD_PROD/Contents/Info.plist" >> "$PREPARED/version.txt"
shasum -a 256 "$PREPARED/VibeBuddyMacApp.app/Contents/MacOS/VibeBuddyMacApp" > "$PREPARED/executable.sha256"
python3 "$REPO/tools/check.py" --source-state > "$PREPARED/source-after.json"
cmp "$PREPARED/source-before.json" "$PREPARED/source-after.json" || { echo "Source changed during preparation; rebuild before installation." >&2; exit 1; }
echo "Prepared (not installed): $PREPARED/VibeBuddyMacApp.app"
echo "After authorization and a fresh peer/device check, use --install with --peer-check-complete."
