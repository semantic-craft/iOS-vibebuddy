#!/usr/bin/env bash
# Screenshot circular + rectangular complication faces on two Watch sizes.
# Uses the Watch app's launch-only complication preview (same views as WidgetKit).
#   tools/watch-complication-qa-shots.sh [output-dir]
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
out="${1:-$repo/.scratch/qa-shots/watch-10}"
derived="${WATCH_QA_DERIVED_DATA:-$repo/.build/watch-complication-qa}"
bundle_id=com.vibebuddy.app.watchkitapp

echo "→ generating + building VibeBuddyWatch"
(cd "$repo/VibeBuddyApp" && xcodegen generate >/dev/null)
xcodebuild -project "$repo/VibeBuddyApp/VibeBuddyApp.xcodeproj" \
  -scheme VibeBuddyWatch -configuration Debug \
  -destination 'generic/platform=watchOS Simulator' \
  -derivedDataPath "$derived" build CODE_SIGNING_ALLOWED=NO >/dev/null

app="$derived/Build/Products/Debug-watchsimulator/VibeBuddyWatch.app"
[[ -d "$app" ]] || { echo "✗ no built app at $app" >&2; exit 1; }

python3 - "$out" "$app" "$bundle_id" <<'PY'
import json, os, subprocess, sys, time

out, app, bundle_id = sys.argv[1], sys.argv[2], sys.argv[3]
runtimes = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "runtimes", "--json"]))["runtimes"]
watch = [r for r in runtimes if r["platform"] == "watchOS" and r["isAvailable"] and r.get("supportedDeviceTypes")]
if not watch:
    sys.exit("✗ no watchOS simulator runtime")
newest = sorted(watch, key=lambda r: r["version"])[-1]
types = newest["supportedDeviceTypes"]

def mm(device):
    digits = "".join(c for c in device["identifier"].split("-")[-1] if c.isdigit())
    return int(digits or 99)

small = min(types, key=mm)
large = max(types, key=mm)
pairs = [(small, "small"), (large, "large")]
if small["identifier"] == large["identifier"]:
    pairs = [(small, "small")]

os.makedirs(out, exist_ok=True)
shots = [
    ("permission", "01-counts"),
    ("noData", "02-placeholder"),
    ("empty", "03-empty-zeros"),
]

def udid_for(name, device_type):
    devices = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "devices", "--json"]))["devices"]
    for items in devices.values():
        for device in items:
            if device["name"] == name:
                return device["udid"]
    return subprocess.check_output(
        ["xcrun", "simctl", "create", name, device_type["identifier"], newest["identifier"]],
        text=True).strip()

for device_type, size in pairs:
    name = f"VibeBuddy Watch QA {size}"
    udid = udid_for(name, device_type)
    subprocess.run(["xcrun", "simctl", "bootstatus", udid, "-b"], check=True, stdout=subprocess.DEVNULL)
    subprocess.run(["xcrun", "simctl", "install", udid, app], check=True)
    for scenario, stem in shots:
        subprocess.run(["xcrun", "simctl", "terminate", udid, bundle_id], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        env = os.environ.copy()
        env["SIMCTL_CHILD_VIBEBUDDY_DEMO"] = "1"
        env["SIMCTL_CHILD_VIBEBUDDY_WATCH_SCENARIO"] = scenario
        env["SIMCTL_CHILD_VIBEBUDDY_WATCH_PAGE"] = "complication"
        subprocess.run(["xcrun", "simctl", "launch", udid, bundle_id], check=True, env=env, stdout=subprocess.DEVNULL)
        time.sleep(3)
        path = os.path.join(out, f"{size}-{stem}.png")
        subprocess.run(["xcrun", "simctl", "io", udid, "screenshot", path], check=True, stdout=subprocess.DEVNULL)
        print(f"  ✓ {os.path.basename(path)}  ({device_type['name']} / {scenario})")

print(f"→ shots in {out}")
PY
