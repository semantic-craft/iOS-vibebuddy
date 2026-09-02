#!/usr/bin/env bash
# End-to-end check of the iPhone → Watch relay on a paired simulator pair.
#   tools/watch-relay-qa.sh [output-dir]
#
# It creates and drives its own paired devices and never touches the installed
# Mac app or :9876. The one non-obvious step is the Watch install: the phone only
# reports its counterpart as installed when the Watch app it is given is the copy
# embedded in the iOS bundle. Install a standalone watchsimulator build instead
# and WatchConnectivity refuses every application context with
# "counterpart app not installed", silently.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
out="${1:-$repo/.scratch/qa-shots/watch-02}"
derived="${WATCH_QA_DERIVED_DATA:-$repo/.build/watch-relay-qa}"
phone_name="${WATCH_RELAY_PHONE:-VibeBuddy Phone QA}"
watch_name="${WATCH_RELAY_WATCH:-VibeBuddy Watch QA}"
phone_id=com.vibebuddy.app
watch_id=com.vibebuddy.app.watchkitapp

device_udid() { # name
  xcrun simctl list devices --json | python3 -c "
import json, sys
for devices in json.load(sys.stdin)['devices'].values():
    for device in devices:
        if device['name'] == '$1':
            print(device['udid']); raise SystemExit"
}

echo "→ building VibeBuddyApp (embeds the Watch app)"
xcodebuild -project "$repo/VibeBuddyApp/VibeBuddyApp.xcodeproj" \
  -scheme VibeBuddyApp -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath "$derived" build CODE_SIGNING_ALLOWED=NO >/dev/null

app="$derived/Build/Products/Debug-iphonesimulator/VibeBuddyApp.app"
[[ -d "$app/Watch/VibeBuddyWatch.app" ]] || { echo "✗ no embedded Watch app in $app" >&2; exit 1; }

read -r ios_runtime watch_runtime watch_type <<<"$(xcrun simctl list runtimes --json | python3 -c '
import json, sys
runtimes = [r for r in json.load(sys.stdin)["runtimes"] if r["isAvailable"]]
def newest(platform):
    matches = [r for r in runtimes if r["platform"] == platform and r.get("supportedDeviceTypes")]
    return sorted(matches, key=lambda r: r["version"])[-1] if matches else None
ios, watch = newest("iOS"), newest("watchOS")
if ios and watch:
    def millimetres(device):
        digits = "".join(c for c in device["identifier"].split("-")[-1] if c.isdigit())
        return int(digits or 99)
    print(ios["identifier"], watch["identifier"],
          min(watch["supportedDeviceTypes"], key=millimetres)["identifier"])')"
[[ -n "${watch_runtime:-}" ]] || { echo "✗ need both an iOS and a watchOS simulator runtime" >&2; exit 1; }

phone="$(device_udid "$phone_name")"
watch="$(device_udid "$watch_name")"
[[ -n "$phone" ]] || phone="$(xcrun simctl create "$phone_name" \
  "$(xcrun simctl list devicetypes --json | python3 -c '
import json, sys
phones = [t for t in json.load(sys.stdin)["devicetypes"] if "iPhone" in t["identifier"]]
print(phones[-1]["identifier"])')" "$ios_runtime")"
[[ -n "$watch" ]] || watch="$(xcrun simctl create "$watch_name" "$watch_type" "$watch_runtime")"

if ! xcrun simctl list pairs | grep -q "$watch"; then
  xcrun simctl shutdown "$watch" 2>/dev/null || true
  xcrun simctl shutdown "$phone" 2>/dev/null || true
  xcrun simctl pair "$watch" "$phone" >/dev/null
fi

echo "→ booting the pair"
xcrun simctl bootstatus "$phone" -b >/dev/null
xcrun simctl bootstatus "$watch" -b >/dev/null

xcrun simctl install "$phone" "$app"
xcrun simctl uninstall "$watch" "$watch_id" 2>/dev/null || true   # also clears stored state
xcrun simctl install "$watch" "$app/Watch/VibeBuddyWatch.app"
sleep 5

mkdir -p "$out"
shoot() { # file
  sleep 5
  xcrun simctl io "$watch" screenshot "$out/$1.png" >/dev/null 2>&1
  echo "  ✓ $1.png"
}

# 1. Nothing has ever been relayed: the honest no-data screen, not invented data.
xcrun simctl terminate "$watch" "$watch_id" 2>/dev/null || true
xcrun simctl launch "$watch" "$watch_id" >/dev/null
shoot 01-watch-before-relay

# 2. The iPhone enters Demo Mode and relays. The Watch must show the *iPhone's*
#    demo projects, not the Watch's own standalone demo scenario.
xcrun simctl terminate "$phone" "$phone_id" 2>/dev/null || true
SIMCTL_CHILD_VIBEBUDDY_DEMO=1 SIMCTL_CHILD_VIBEBUDDY_SKIP_NOTIFICATIONS=1 \
  xcrun simctl launch "$phone" "$phone_id" >/dev/null
shoot 02-watch-after-relay
xcrun simctl io "$phone" screenshot "$out/03-phone-demo.png" >/dev/null 2>&1

# 3. A cold Watch launch restores what it was last told.
xcrun simctl terminate "$watch" "$watch_id"
sleep 2
xcrun simctl launch "$watch" "$watch_id" >/dev/null
shoot 05-watch-cold-launch-restore

# 4. The iPhone cannot reach the Mac: the Watch says so and shows the age.
xcrun simctl terminate "$phone" "$phone_id"
SIMCTL_CHILD_VIBEBUDDY_HOST=127.0.0.1 SIMCTL_CHILD_VIBEBUDDY_PORT=18799 \
SIMCTL_CHILD_VIBEBUDDY_TOKEN=nobody SIMCTL_CHILD_VIBEBUDDY_SKIP_NOTIFICATIONS=1 \
  xcrun simctl launch "$phone" "$phone_id" >/dev/null
sleep 7
shoot 06-watch-disconnected

echo "→ shots in $out"
echo "  Resolving an approval on the phone (04-watch-after-approve) needs a real"
echo "  tap; simctl cannot drive the iOS UI."
