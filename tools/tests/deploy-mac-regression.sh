#!/usr/bin/env bash
# Exercise the real replacement transaction against disposable app directories.
set -euo pipefail
repo="$(cd "$(dirname "$0")/../.." && pwd)"
if [[ "${1:-}" == --case ]]; then
  source "$repo/tools/lib/install-mac-app.sh"
  root="$2"
  mode="$3"
  verify_app() { [[ "$mode" != bad-signature ]]; }
  ditto() {
    [[ "$mode" != copy-failure ]] || return 1
    cp -R "$1" "$2"
  }
  mv() {
    if [[ "$mode" == restore-move-failure && "$1" == */previous.app ]]; then return 1; fi
    command mv "$@"
  }
  app_running() { [[ -e "$root/running" ]]; }
  stop_app() {
    [[ "$mode" != stop-failure ]] || return 1
    if [[ "$mode" == foreign-after-exit && "$(cat "$1/version")" == new ]]; then
      rm -f "$root/running"
      return 1
    fi
    rm -f "$root/running"
  }
  start_app() {
    if [[ "$mode" == launch-failure && "$(cat "$1/version")" == new ]]; then return 1; fi
    touch "$root/running"
  }
  app_ready() {
    [[ "$mode" != health-failure && "$mode" != restore-move-failure && "$mode" != foreign-after-exit || "$(cat "$1/version")" != new ]]
  }
  install_mac_app "$root/candidate.app" "$root/Applications/VibeBuddyMacApp.app"
  exit
fi
fixture="$(mktemp -d "${TMPDIR:-/tmp}/vb-install-tests.XXXXXX")"
trap 'rm -rf "$fixture"' EXIT
for mode in success copy-failure bad-signature launch-failure health-failure stop-failure locked first-install-failure restore-move-failure foreign-after-exit; do
  root="$fixture/$mode"
  mkdir -p "$root/candidate.app" "$root/Applications/VibeBuddyMacApp.app"
  echo new > "$root/candidate.app/version"
  echo old > "$root/Applications/VibeBuddyMacApp.app/version"
  touch "$root/running"
  expected=old
  case_mode="$mode"
  if [[ "$mode" == locked ]]; then mkdir "$root/Applications/.VibeBuddyMacApp.app.install-lock"; fi
  if [[ "$mode" == first-install-failure ]]; then
    rm -rf "$root/Applications/VibeBuddyMacApp.app"
    rm "$root/running"
    case_mode=launch-failure
  fi
  if bash "$0" --case "$root" "$case_mode" > "$root/result.log" 2>&1; then
    [[ "$mode" == success ]] || { cat "$root/result.log"; exit 1; }
    expected=new
  else
    [[ "$mode" != success ]] || { cat "$root/result.log"; exit 1; }
  fi
  if [[ "$mode" == restore-move-failure ]]; then
    lock="$root/Applications/.VibeBuddyMacApp.app.install-lock"
    [[ -f "$lock/owner.txt" ]]
    grep -q 'recovery=' "$lock/owner.txt"
    grep -q 'Installation evidence / recovery:' "$root/result.log"
    [[ ! -e "$root/Applications/VibeBuddyMacApp.app" ]]
    echo "PASS $mode"
    continue
  fi
  if [[ "$mode" == first-install-failure ]]; then
    [[ ! -e "$root/Applications/VibeBuddyMacApp.app" && ! -e "$root/running" ]]
  else
    [[ "$(cat "$root/Applications/VibeBuddyMacApp.app/version")" == "$expected" ]]
    [[ -e "$root/running" ]]
  fi
  if [[ "$mode" != locked ]]; then [[ ! -d "$root/Applications/.VibeBuddyMacApp.app.install-lock" ]]; fi
  if [[ "$mode" == success ]]; then
    backups=("$root"/Applications/.VibeBuddyMacApp.app.install.*/previous.app/version)
    [[ "$(cat "${backups[0]}")" == old ]]
  fi
  echo "PASS $mode"
done
# Argument errors must exit before builds, keychain access or installation.
if bash "$repo/tools/redeploy-mac.sh" --install /unused > "$fixture/guard.log" 2>&1; then exit 1; fi
bash "$repo/tools/redeploy-mac.sh" --help > /dev/null
echo 'PASS install authorization/check acknowledgement argument guard'

if [[ "$(uname -s)" == Darwin ]]; then
  source "$repo/tools/lib/mac-app-runtime.sh"
  app="$fixture/signed.app"
  mkdir -p "$app/Contents/MacOS"
  cp /usr/bin/true "$app/Contents/MacOS/VibeBuddyMacApp"
  cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.vibebuddy.mac</string>
<key>CFBundleExecutable</key><string>VibeBuddyMacApp</string>
<key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
PLIST
  codesign --force --sign - "$app" > "$fixture/sign.log" 2>&1
  verify_app "$app"
  echo tampered >> "$app/Contents/Info.plist"
  if verify_app "$app" > "$fixture/tampered.log" 2>&1; then exit 1; fi
  echo 'PASS native signature verification and tamper rejection (ad-hoc fixture, never launched)'
else
  echo 'SKIP native signature verification: requires macOS'
fi

# Run the production stop function with deterministic process/syscall boundaries.
(
  source "$repo/tools/lib/mac-app-runtime.sh"
  app_pids() { echo '101 102'; }
  pid_is_app() { [[ "$1" == 101 ]]; }
  kill() {
    [[ "$1" == -0 ]] && return 0
    echo signal >> "$fixture/signals"
  }
  if stop_app /fixture > /dev/null 2>&1; then exit 1; fi
  [[ ! -e "$fixture/signals" ]]
  app_pids() { echo 101; }
  pid_is_app() { return 0; }
  calls=0
  kill() {
    if [[ "$1" == -TERM ]]; then calls=1; return 1; fi
    [[ "$calls" == 0 ]]
  }
  stop_app /fixture
  echo 'PASS runtime classifies before signaling and tolerates ESRCH'
)
