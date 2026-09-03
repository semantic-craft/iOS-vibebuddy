#!/usr/bin/env bash
# Screenshot every deterministic Watch demo scenario on a watchOS Simulator.
#   tools/watch-qa-shots.sh [output-dir]
# Each scenario is a pure function of its launch environment, so re-running this
# reproduces the same screens. It touches only its own simulator device and
# never the installed Mac app or :9876.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
out="${1:-$repo/.scratch/qa-shots/watch-01}"
derived="${WATCH_QA_DERIVED_DATA:-$repo/.build/watch-qa}"
device_name="${WATCH_QA_DEVICE:-VibeBuddy Watch QA}"
bundle_id=com.vibebuddy.app.watchkitapp

# scenario:page:filename
shots=(
  "normal:home:01-normal-home"
  "permission:home:02-permission-takeover"
  "question:home:03-question-takeover"
  "empty:home:04-no-sessions"
  "normal:quota:05-quota-live"
  "staleQuota:quota:06-quota-stale"
  "unavailableQuota:quota:07-quota-unavailable"
  "noData:home:08-no-data"
  "macDisconnected:home:15-mac-disconnected"
  "phoneDisconnected:home:16-phone-disconnected"
  "watchUnreachable:home:17-watch-unreachable"
)

echo "→ building VibeBuddyWatch"
xcodebuild -project "$repo/VibeBuddyApp/VibeBuddyApp.xcodeproj" \
  -scheme VibeBuddyWatch -configuration Debug \
  -destination 'generic/platform=watchOS Simulator' \
  -derivedDataPath "$derived" build CODE_SIGNING_ALLOWED=NO >/dev/null

app="$derived/Build/Products/Debug-watchsimulator/VibeBuddyWatch.app"
[[ -d "$app" ]] || { echo "✗ no built app at $app" >&2; exit 1; }

read -r runtime device_type <<<"$(xcrun simctl list runtimes --json | python3 -c '
import json, sys
runtimes = [r for r in json.load(sys.stdin)["runtimes"]
            if r["platform"] == "watchOS" and r["isAvailable"] and r.get("supportedDeviceTypes")]
if runtimes:
    newest = sorted(runtimes, key=lambda r: r["version"])[-1]
    supported = newest["supportedDeviceTypes"]
    # Shoot on the tightest screen the runtime supports: layout problems show
    # up there first, and anything that fits there fits the larger watches.
    def millimetres(device):
        digits = "".join(c for c in device["identifier"].split("-")[-1] if c.isdigit())
        return int(digits or 99)
    print(newest["identifier"], min(supported, key=millimetres)["identifier"])')"
[[ -n "${runtime:-}" ]] || { echo "✗ no watchOS simulator runtime — run: xcodebuild -downloadPlatform watchOS" >&2; exit 1; }
device_type="${WATCH_QA_DEVICE_TYPE:-$device_type}"

udid="$(xcrun simctl list devices --json | python3 -c "
import json, sys
for devices in json.load(sys.stdin)['devices'].values():
    for device in devices:
        if device['name'] == '$device_name':
            print(device['udid']); raise SystemExit")"
if [[ -z "$udid" ]]; then
  udid="$(xcrun simctl create "$device_name" "$device_type" "$runtime")"
fi

echo "→ booting $device_name ($udid)"
xcrun simctl bootstatus "$udid" -b >/dev/null
xcrun simctl install "$udid" "$app"

mkdir -p "$out"
for shot in "${shots[@]}"; do
  IFS=: read -r scenario page name <<<"$shot"
  xcrun simctl terminate "$udid" "$bundle_id" >/dev/null 2>&1 || true
  SIMCTL_CHILD_VIBEBUDDY_DEMO=1 \
  SIMCTL_CHILD_VIBEBUDDY_WATCH_SCENARIO="$scenario" \
  SIMCTL_CHILD_VIBEBUDDY_WATCH_PAGE="$page" \
    xcrun simctl launch "$udid" "$bundle_id" >/dev/null
  sleep 3
  xcrun simctl io "$udid" screenshot "$out/$name.png" >/dev/null 2>&1
  echo "  ✓ $name.png  ($scenario / $page)"
done

# noData ignores VIBEBUDDY_DEMO by design; take it with demo mode off too so the
# onboarding screen is proven to be what an unpaired Watch really shows.
xcrun simctl terminate "$udid" "$bundle_id" >/dev/null 2>&1 || true
xcrun simctl launch "$udid" "$bundle_id" >/dev/null
sleep 3
xcrun simctl io "$udid" screenshot "$out/09-unpaired.png" >/dev/null 2>&1
echo "  ✓ 09-unpaired.png  (no demo mode)"

# Simplified Chinese and the largest accessibility text size, on the screens
# carrying the most copy. The watchOS runtime rejects `simctl ui content_size`,
# so text size comes in through the app's own argument domain instead.
shoot() { # scenario page filename [extra launch args…]
  local scenario="$1" page="$2" name="$3"; shift 3
  xcrun simctl terminate "$udid" "$bundle_id" >/dev/null 2>&1 || true
  SIMCTL_CHILD_VIBEBUDDY_DEMO=1 \
  SIMCTL_CHILD_VIBEBUDDY_WATCH_SCENARIO="$scenario" \
  SIMCTL_CHILD_VIBEBUDDY_WATCH_PAGE="$page" \
    xcrun simctl launch "$udid" "$bundle_id" "$@" >/dev/null
  sleep 3
  xcrun simctl io "$udid" screenshot "$out/$name.png" >/dev/null 2>&1
  echo "  ✓ $name.png"
}

big=(-UIPreferredContentSizeCategoryName UICTContentSizeCategoryAccessibilityL)

shoot permission home 10-permission-zh-Hans -AppleLanguages "(zh-Hans)"
shoot staleQuota quota 11-quota-zh-Hans -AppleLanguages "(zh-Hans)"
shoot permission home 12-permission-large-text "${big[@]}"
shoot normal home 13-overview-large-text "${big[@]}"
shoot staleQuota quota 14-quota-large-text "${big[@]}"

echo "→ shots in $out"
