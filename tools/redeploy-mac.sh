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

print_running_app_processes() {
  local pids=()
  local pid
  while IFS= read -r pid; do
    [[ -n "$pid" ]] && pids+=("$pid")
  done < <(pgrep -x VibeBuddyMacApp 2>/dev/null || true)

  if ((${#pids[@]} > 0)); then
    local joined
    joined="$(IFS=,; echo "${pids[*]}")"
    ps -o pid,ppid,stat,etime,command -p "$joined"
  fi
}

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
if pids="$(pgrep -x VibeBuddyMacApp 2>/dev/null)"; then
  echo "▸ stopping existing VibeBuddyMacApp process(es): ${pids//$'\n'/ }"
  kill -9 $pids 2>/dev/null || true
fi
sleep 1
rm -rf "$DEST"
ditto "$BUILD_PROD" "$DEST"
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true
xattr -dr com.apple.provenance "$DEST" 2>/dev/null || true
open "$DEST"
for _ in $(seq 1 80); do
  if curl -fsS --max-time 1 http://127.0.0.1:9876/health >/dev/null 2>&1; then
    break
  fi
  sleep 0.5
done
if ! curl -fsS --max-time 2 http://127.0.0.1:9876/health >/dev/null; then
  echo "✗ app launched but /health did not become ready on :9876" >&2
  exit 1
fi
running="$(pgrep -x VibeBuddyMacApp | wc -l | tr -d ' ')"
if [[ "$running" != "1" ]]; then
  echo "✗ expected exactly one VibeBuddyMacApp process, found $running" >&2
  print_running_app_processes >&2
  exit 1
fi
print_running_app_processes
echo "✓ done. On the next keychain prompt, click \"Always Allow\" once — it now sticks across rebuilds."
