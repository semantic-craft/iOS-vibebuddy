#!/usr/bin/env bash
# Break each link of Mac → iPhone → Watch in turn, and record what the Watch
# says about it.
#   tools/watch-connection-qa.sh [output-dir]
#
# The daemon runs on an isolated port with a temporary HOME and journal, so the
# installed menu-bar app and :9876 are never touched. It assumes the paired
# simulator pair that tools/watch-relay-qa.sh sets up.
#
# Two of the four states only exist once the relayed state has aged past
# WatchDashboardState.staleAfter (15 minutes), so this run is deliberately slow:
# it waits the boundary out rather than faking a clock. Override the wait with
# WATCH_STALE_WAIT (seconds) only to shorten a smoke run — a shorter wait proves
# nothing about the boundary.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
out="${1:-$repo/.scratch/qa-shots/watch-07}"
derived="${WATCH_QA_DERIVED_DATA:-$repo/.build/watch-connection-qa}"
port="${VIBEBUDDY_QA_PORT:-18766}"
token="${VIBEBUDDY_QA_TOKEN:-watch07}"
stale_wait="${WATCH_STALE_WAIT:-1020}"      # 15 min boundary + 2 min of slack
phone_name="${WATCH_RELAY_PHONE:-VibeBuddy Phone QA}"
watch_name="${WATCH_RELAY_WATCH:-VibeBuddy Watch QA}"
phone_id=com.vibebuddy.app
watch_id=com.vibebuddy.app.watchkitapp

work="$(mktemp -d)"
daemon_pid=""
cleanup() {
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

start_daemon() {
  HOME="$work" VIBEBUDDY_PORT="$port" VIBEBUDDY_TOKEN="$token" \
  VIBEBUDDY_JOURNAL_PATH="$work/journal.json" \
  VIBEBUDDY_DELIVERY_LOG_PATH="$work/delivery.json" \
    "$repo/VibeBuddyMac/.build/debug/vibebuddyd" >>"$work/daemon.log" 2>&1 &
  daemon_pid=$!
  for _ in $(seq 1 40); do
    curl -fsS "http://127.0.0.1:$port/health" >/dev/null 2>&1 && return
    sleep 0.5
  done
  echo "✗ daemon never came up" >&2; exit 1
}

hook() { # json [agent]
  curl -fsS -X POST "http://127.0.0.1:$port/hook?agent=${2:-claude}" \
    -H "Authorization: Bearer $token" -d "$1" >/dev/null
}

launch_phone() {
  xcrun simctl terminate "$phone" "$phone_id" 2>/dev/null || true
  SIMCTL_CHILD_VIBEBUDDY_HOST=127.0.0.1 SIMCTL_CHILD_VIBEBUDDY_PORT="$port" \
  SIMCTL_CHILD_VIBEBUDDY_TOKEN="$token" SIMCTL_CHILD_VIBEBUDDY_SKIP_NOTIFICATIONS=1 \
    xcrun simctl launch "$phone" "$phone_id" >/dev/null
}

shoot() { # file [seconds]
  sleep "${2:-8}"
  xcrun simctl io "$watch" screenshot "$out/$1.png" >/dev/null 2>&1
  echo "  ✓ $1.png"
}

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
start_daemon
hook '{"hook_event_name":"UserPromptSubmit","session_id":"conn-gateway","cwd":"/Users/qa/Projects/api-gateway"}'
hook '{"hook_event_name":"UserPromptSubmit","session_id":"conn-indexer","cwd":"/Users/qa/Projects/search-indexer"}' codex
hook '{"hook_event_name":"Stop","session_id":"conn-docs","cwd":"/Users/qa/Projects/docs-site","message":"Published the release notes."}'

echo "→ installing on the pair"
xcrun simctl bootstatus "$phone" -b >/dev/null
xcrun simctl bootstatus "$watch" -b >/dev/null
xcrun simctl install "$phone" "$app"
xcrun simctl uninstall "$watch" "$watch_id" 2>/dev/null || true   # also clears stored state
xcrun simctl install "$watch" "$app/Watch/VibeBuddyWatch.app"
sleep 5

mkdir -p "$out"

echo "→ layer 0: everything up"
launch_phone
xcrun simctl launch "$watch" "$watch_id" >/dev/null
shoot 01-live 10

echo "→ layer 1: the Mac daemon goes away"
kill "$daemon_pid" 2>/dev/null || true
daemon_pid=""
shoot 02-mac-disconnected 15

echo "→ layer 1 recovery: the daemon comes back"
start_daemon
hook '{"hook_event_name":"UserPromptSubmit","session_id":"conn-gateway","cwd":"/Users/qa/Projects/api-gateway"}'
shoot 03-mac-recovered 15

echo "→ layer 2: the iPhone app stops relaying (waiting out ${stale_wait}s of staleness)"
xcrun simctl terminate "$phone" "$phone_id" 2>/dev/null || true
sleep "$stale_wait"
shoot 04-phone-disconnected 5

echo "→ layer 3: the Watch loses the iPhone entirely"
xcrun simctl shutdown "$phone" >/dev/null 2>&1 || true
shoot 05-watch-unreachable 20

echo "→ recovery: the iPhone comes back and relays again"
xcrun simctl bootstatus "$phone" -b >/dev/null
launch_phone
shoot 06-recovered 20

echo "→ the iPhone relays from the background"
# Foreground another app so ours is backgrounded but not yet suspended, then
# change the world on the Mac. The application context is a background transfer,
# so the wrist must still learn about the new waiting session.
xcrun simctl launch "$phone" com.apple.Preferences >/dev/null 2>&1 \
  || xcrun simctl launch "$phone" com.apple.mobilesafari >/dev/null 2>&1 || true
sleep 3
hook '{"hook_event_name":"Notification","session_id":"conn-review","cwd":"/Users/qa/Projects/docs-review","message":"Which revision style should I use?"}'
shoot 07-backgrounded-relay 12

echo "→ shots in $out"
