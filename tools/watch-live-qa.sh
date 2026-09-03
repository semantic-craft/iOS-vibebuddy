#!/usr/bin/env bash
# Drive the whole Mac → iPhone → Watch path with a real daemon.
#   tools/watch-live-qa.sh [output-dir]
#
# The daemon runs on an isolated port with a temporary HOME and journal, so the
# installed menu-bar app and :9876 are never touched. It assumes the paired
# simulator pair that tools/watch-relay-qa.sh sets up.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
out="${1:-$repo/.scratch/qa-shots/watch-03}"
derived="${WATCH_QA_DERIVED_DATA:-$repo/.build/watch-live-qa}"
port="${VIBEBUDDY_QA_PORT:-18765}"
token="${VIBEBUDDY_QA_TOKEN:-watch03}"
phone_name="${WATCH_RELAY_PHONE:-VibeBuddy Phone QA}"
watch_name="${WATCH_RELAY_WATCH:-VibeBuddy Watch QA}"
phone_id=com.vibebuddy.app
watch_id=com.vibebuddy.app.watchkitapp

work="$(mktemp -d)"
daemon_pid=""
approval_pid=""
cleanup() {
  [[ -n "$approval_pid" ]] && kill "$approval_pid" 2>/dev/null || true
  [[ -n "$daemon_pid" ]] && kill "$daemon_pid" 2>/dev/null || true
  rm -rf "$work"
}
trap cleanup EXIT

device_udid() { # name
  xcrun simctl list devices --json | python3 -c "
import json, sys
for devices in json.load(sys.stdin)['devices'].values():
    for device in devices:
        if device['name'] == '$1':
            print(device['udid']); raise SystemExit"
}

phone="$(device_udid "$phone_name")"
watch="$(device_udid "$watch_name")"
[[ -n "$phone" && -n "$watch" ]] || {
  echo "✗ run tools/watch-relay-qa.sh first — it creates and pairs the devices" >&2; exit 1; }

echo "→ building vibebuddyd and VibeBuddyApp"
# Building the package on its own re-resolves without the Mac app's Sparkle pin
# and rewrites Package.resolved. Put it back so a QA run never dirties the tree.
cp "$repo/VibeBuddyMac/Package.resolved" "$work/Package.resolved.bak"
(cd "$repo/VibeBuddyMac" && swift build >/dev/null)
cp "$work/Package.resolved.bak" "$repo/VibeBuddyMac/Package.resolved"
xcodebuild -project "$repo/VibeBuddyApp/VibeBuddyApp.xcodeproj" \
  -scheme VibeBuddyApp -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath "$derived" build CODE_SIGNING_ALLOWED=NO >/dev/null
app="$derived/Build/Products/Debug-iphonesimulator/VibeBuddyApp.app"

echo "→ starting an isolated daemon on :$port"
HOME="$work" VIBEBUDDY_PORT="$port" VIBEBUDDY_TOKEN="$token" \
VIBEBUDDY_JOURNAL_PATH="$work/journal.json" \
VIBEBUDDY_DELIVERY_LOG_PATH="$work/delivery.json" \
  "$repo/VibeBuddyMac/.build/debug/vibebuddyd" >"$work/daemon.log" 2>&1 &
daemon_pid=$!
for _ in $(seq 1 40); do
  curl -fsS "http://127.0.0.1:$port/health" >/dev/null 2>&1 && break
  sleep 0.5
done
curl -fsS "http://127.0.0.1:$port/health" >/dev/null || { echo "✗ daemon never came up" >&2; exit 1; }

hook() { # json [agent]
  curl -fsS -X POST "http://127.0.0.1:$port/hook?agent=${2:-claude}" \
    -H "Authorization: Bearer $token" -d "$1" >/dev/null
}

echo "→ seeding sessions"
hook '{"hook_event_name":"SessionStart","session_id":"live-gateway","cwd":"/Users/qa/Projects/api-gateway","model":"claude-opus-4-8"}'
hook '{"hook_event_name":"UserPromptSubmit","session_id":"live-gateway","cwd":"/Users/qa/Projects/api-gateway"}'
hook '{"hook_event_name":"UserPromptSubmit","session_id":"live-indexer","cwd":"/Users/qa/Projects/search-indexer"}' codex
hook '{"hook_event_name":"Stop","session_id":"live-docs","cwd":"/Users/qa/Projects/docs-site","message":"Published the release notes."}'
hook '{"hook_event_name":"Notification","session_id":"live-review","cwd":"/Users/qa/Projects/docs-review","message":"Which revision style should I use?"}'

# A blocking permission prompt, exactly as a CLI hook would make one.
hook '{"hook_event_name":"UserPromptSubmit","session_id":"live-build","cwd":"/Users/qa/Projects/ios-vibebuddy"}'
curl -fsS -X POST "http://127.0.0.1:$port/approval" -H "Authorization: Bearer $token" -d '{
  "session_id":"live-build","tool_name":"Bash",
  "tool_input":{"command":"xcodebuild -scheme VibeBuddyWatch -destination \"platform=watchOS Simulator\" build"}
}' >/dev/null &
approval_pid=$!
sleep 2

mkdir -p "$out"
shoot() { # file [seconds]
  sleep "${2:-6}"
  xcrun simctl io "$watch" screenshot "$out/$1.png" >/dev/null 2>&1
  echo "  ✓ $1.png"
}
launch_watch() { # page
  xcrun simctl terminate "$watch" "$watch_id" 2>/dev/null || true
  SIMCTL_CHILD_VIBEBUDDY_WATCH_PAGE="${1:-home}" \
    xcrun simctl launch "$watch" "$watch_id" >/dev/null
}

echo "→ pointing the iPhone at the daemon"
xcrun simctl install "$phone" "$app"
xcrun simctl uninstall "$watch" "$watch_id" 2>/dev/null || true
xcrun simctl install "$watch" "$app/Watch/VibeBuddyWatch.app"
sleep 5
xcrun simctl terminate "$phone" "$phone_id" 2>/dev/null || true
SIMCTL_CHILD_VIBEBUDDY_HOST=127.0.0.1 SIMCTL_CHILD_VIBEBUDDY_PORT="$port" \
SIMCTL_CHILD_VIBEBUDDY_TOKEN="$token" SIMCTL_CHILD_VIBEBUDDY_SKIP_NOTIFICATIONS=1 \
  xcrun simctl launch "$phone" "$phone_id" >/dev/null
launch_watch home
shoot 01-live-permission-takeover
launch_watch alerts
shoot 02-live-alerts-page

echo "→ resolving the permission on the Mac"
approval_id="$(curl -fsS "http://127.0.0.1:$port/snapshot" -H "Authorization: Bearer $token" \
  | python3 -c 'import json,sys
sessions = json.load(sys.stdin)["sessions"]
print(next((s["pendingApproval"]["id"] for s in sessions if s.get("pendingApproval")), ""))')"
[[ -n "$approval_id" ]] || { echo "✗ no pending approval in the snapshot" >&2; exit 1; }
curl -fsS -X POST "http://127.0.0.1:$port/decision" -H "Authorization: Bearer $token" \
  -d "{\"approvalId\":\"$approval_id\",\"decision\":\"allow\"}" >/dev/null
launch_watch home
shoot 03-live-promoted-to-question

echo "→ answering the question on the Mac"
hook '{"hook_event_name":"UserPromptSubmit","session_id":"live-review","cwd":"/Users/qa/Projects/docs-review"}'
shoot 04-live-nobody-waiting

echo "→ stopping the daemon"
kill "$daemon_pid" 2>/dev/null || true
daemon_pid=""
shoot 05-live-mac-gone 15

echo "→ shots in $out"
