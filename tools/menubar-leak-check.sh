#!/usr/bin/env bash
# Regression check for the MenuBarExtraAccess observer leak (PR #290).
#
#   tools/menubar-leak-check.sh [path/to/VibeBuddyMacApp.app]
#
# Runs an isolated E2E copy of a built app (bundle id com.vibebuddy.e2e.leakcheck,
# own root and port, never :9876 or the installed app), sends hook events for
# ~2 minutes, and counts live MenuBarExtraAccess instances with `heap`. Before the
# fix every model change leaked one (82 -> 320 in 4 min); after it the count stays
# flat. Exits 1 if the count grew by more than 2.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="${1:-$REPO/VibeBuddyMacApp/build/Build/Products/Debug/VibeBuddyMacApp.app}"
PORT="${VIBEBUDDY_LEAKCHECK_PORT:-18794}"
[[ "$PORT" != 9876 ]] || { echo "refusing :9876" >&2; exit 2; }
[[ -d "$SRC" ]] || { echo "no app at $SRC (build the VibeBuddyMacApp scheme first)" >&2; exit 2; }

ID=leakcheck
BID="com.vibebuddy.e2e.$ID"
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/vb-leakcheck.XXXXXX")"
APP="$ROOT/VibeBuddyE2E.app"
PID=""
cleanup() {
  [[ -n "$PID" ]] && kill -9 "$PID" 2>/dev/null || true   # SIGTERM is deferred by the app
  defaults delete "$BID" >/dev/null 2>&1 || true
  rm -rf "$ROOT"
}
trap cleanup EXIT

ditto "$SRC" "$APP"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BID" "$APP/Contents/Info.plist"
codesign --force --deep --sign - "$APP" 2>/dev/null
VIBEBUDDY_E2E_ROOT="$ROOT/state" VIBEBUDDY_E2E_ID="$ID" VIBEBUDDY_E2E_PORT="$PORT" \
  "$APP/Contents/MacOS/VibeBuddyMacApp" -showGlance NO >"$ROOT/app.log" 2>&1 &
PID=$!
for _ in $(seq 1 60); do
  curl -fsS --max-time 1 "http://127.0.0.1:$PORT/health" >/dev/null 2>&1 && break
  sleep 0.5
done
TOKEN="$(cat "$ROOT/state/token")"

hook() {
  curl -fsS -o /dev/null -X POST "http://127.0.0.1:$PORT/hook?agent=claude" \
    -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' --data-binary "$1"
}
count() {
  heap "$PID" -s 2>/dev/null \
    | awk '$4 ~ /^MenuBarExtraAccess\.MenuBarExtraAccess</ { print $1; found = 1 } END { if (!found) print 0 }'
}
drive() {
  local i s
  for i in $(seq "$1" "$2"); do
    s="leak-s$((i % 4))"
    hook "{\"hook_event_name\":\"UserPromptSubmit\",\"session_id\":\"$s\",\"cwd\":\"/tmp/leak\",\"prompt\":\"go $i\"}"
    hook "{\"hook_event_name\":\"Stop\",\"session_id\":\"$s\",\"cwd\":\"/tmp/leak\",\"last_assistant_message\":\"done $i\"}"
    sleep 2
  done
}

drive 1 15
first="$(count)"
drive 16 60
last="$(count)"
echo "MenuBarExtraAccess instances: $first after ~30 s, $last after ~2 min"
(( last - first <= 2 )) || { echo "FAIL: the menu-bar modifier is being re-created and leaking observers" >&2; exit 1; }
echo "PASS"
