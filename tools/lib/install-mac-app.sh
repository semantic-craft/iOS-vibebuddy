#!/usr/bin/env bash
# Transaction shared by the production installer and disposable regression tests.
# Caller supplies verify_app, stop_app, start_app, app_ready and app_running.
install_mac_app() (
  set -euo pipefail
  source_app="$1"
  destination="$2"
  parent="$(dirname "$destination")"
  name="$(basename "$destination")"
  lock="$parent/.$name.install-lock"
  [[ -d "$source_app" && ! -L "$destination" ]] || exit 1
  mkdir "$lock" || { echo "Installation already reserved: $lock" >&2; exit 1; }
  work=""
  success=0
  stopped=0
  was_running=0
  had_previous=0
  [[ ! -e "$destination" ]] || had_previous=1
  app_running "$destination" && was_running=1
  # Called from the EXIT handler.
  # shellcheck disable=SC2329
  release_lock() {
    rm -f "$lock/owner.txt"
    rmdir "$lock"
  }
  # Called by EXIT, including signal/error paths.
  # shellcheck disable=SC2329
  finish() {
    result=$?
    trap - EXIT INT TERM
    [[ -z "$work" ]] || echo "Installation evidence / recovery: $work"
    if (( ! success && stopped )); then
      # A missing staged bundle means it has been moved into destination.
      if [[ ! -e "$work/$name" && -e "$destination" ]]; then
        if ! stop_app "$destination" && app_running "$destination"; then
          echo "Cannot stop candidate; recovery files preserved at $work" >&2
          exit 1
        fi
        mv "$destination" "$work/failed.app" || { echo "Restore failed; lock and recovery pointer retained at $lock" >&2; exit 1; }
      fi
      if [[ -e "$work/previous.app" ]]; then
        mv "$work/previous.app" "$destination" || { echo "Restore failed; lock and recovery pointer retained at $lock" >&2; exit 1; }
      fi
      if (( had_previous && was_running )); then
        if start_app "$destination" && app_ready "$destination"; then
          echo "Previous app restored and healthy."
        else
          echo "Previous app restored on disk; restart/health failed." >&2
        fi
      fi
    fi
    release_lock
    exit "$result"
  }
  trap finish EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  printf 'pid=%s\nsource=%s\ndestination=%s\n' "$$" "$source_app" "$destination" > "$lock/owner.txt"
  work="$(mktemp -d "$parent/.$name.install.XXXXXX")"
  printf 'recovery=%s\n' "$work" >> "$lock/owner.txt"
  printf '%s\n' "source=$source_app" "destination=$destination" > "$work/operation.txt"
  # Copy and verify before stopping anything. Rename stays on the same volume.
  ditto "$source_app" "$work/$name" || exit 1
  verify_app "$work/$name" || exit 1
  stop_app "$destination" || exit 1
  stopped=1
  if (( had_previous )); then mv "$destination" "$work/previous.app" || exit 1; fi
  mv "$work/$name" "$destination" || exit 1
  start_app "$destination" || exit 1
  app_ready "$destination" || exit 1
  success=1
  echo "Installed candidate is healthy; previous app retained at $work/previous.app"
)
