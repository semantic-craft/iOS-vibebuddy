#!/usr/bin/env bash
# macOS effects for install-mac-app.sh. No effect occurs when this file is sourced.
verify_app() {
  codesign --verify --deep --strict "$1" || return 1
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$1/Contents/Info.plist")" == com.vibebuddy.mac ]] || return 1
  [[ -x "$1/Contents/MacOS/VibeBuddyMacApp" ]] || return 1
}
app_pids() { pgrep -x VibeBuddyMacApp || true; }
pid_is_app() {
  lsof -a -p "$1" -d txt -Fn 2>/dev/null | grep -Fx "n$2/Contents/MacOS/VibeBuddyMacApp" >/dev/null
}
app_running() {
  local pid
  for pid in $(app_pids); do
    if pid_is_app "$pid" "$1"; then return 0; fi
  done
  return 1
}
stop_app() {
  local pid attempt
  local targets=()
  # Classify the complete snapshot before signaling any process.
  for pid in $(app_pids); do
    kill -0 "$pid" 2>/dev/null || continue
    if ! pid_is_app "$pid" "$1"; then
      kill -0 "$pid" 2>/dev/null || continue
      echo "Another app instance exists (PID $pid); refusing to stop it." >&2
      return 1
    fi
    targets+=("$pid")
  done
  ((${#targets[@]})) || return 0
  for pid in "${targets[@]}"; do
    if ! kill -TERM "$pid" 2>/dev/null; then
      kill -0 "$pid" 2>/dev/null || continue
      return 1
    fi
    for ((attempt=0; attempt<40; attempt++)); do
      kill -0 "$pid" 2>/dev/null || break
      sleep 0.25
    done
    if kill -0 "$pid" 2>/dev/null; then
      echo "App PID $pid did not quit; installation stopped." >&2
      return 1
    fi
  done
}
start_app() { open "$1"; }
app_ready() {
  local bundle="$1" attempt pid pids listener
  for ((attempt=0; attempt<80; attempt++)); do
    pids="$(app_pids)"
    if [[ -n "$pids" && "$pids" != *$'\n'* ]]; then
      pid="$pids"
      listener="$(lsof -nP -a -p "$pid" -iTCP:9876 -sTCP:LISTEN -t 2>/dev/null || true)"
      if [[ "$listener" == "$pid" ]] && pid_is_app "$pid" "$bundle" \
        && [[ "$(curl -fsS --max-time 1 http://127.0.0.1:9876/health 2>/dev/null)" == ok ]]; then
        codesign --verify --deep --strict "$bundle" || return 1
        echo "Healthy PID $pid at $bundle; version/build:"
        /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$bundle/Contents/Info.plist"
        /usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$bundle/Contents/Info.plist"
        return 0
      fi
    fi
    sleep 0.5
  done
  echo "Candidate did not own :9876 with a healthy, unique app process." >&2
  return 1
}
