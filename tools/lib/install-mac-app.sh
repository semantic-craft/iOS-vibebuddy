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
  contract="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/install-contract.py"
  # Preserve the caller's stdout for the final machine result only.
  exec 3>&1
  if [[ "${INSTALL_JSON:-0}" == 1 ]]; then exec 1>&2; fi
  work=""
  success=0
  stage=preflight
  rollback=not_needed
  lock_owned=0
  stopped=0
  was_running=0
  had_previous=0
  [[ ! -e "$destination" ]] || had_previous=1
  app_running "$destination" && was_running=1
  # Called from the EXIT handler.
  # shellcheck disable=SC2329
  release_lock() {
    (( lock_owned )) || return 0
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
      rollback=failed
      # A missing staged bundle means it has been moved into destination.
      if [[ ! -e "$work/$name" && -e "$destination" ]]; then
        if ! stop_app "$destination" && app_running "$destination"; then
          echo "Cannot stop candidate; recovery files preserved at $work" >&2
          emit_receipt 1
        fi
        mv "$destination" "$work/failed.app" || { echo "Restore failed; lock and recovery pointer retained at $lock" >&2; emit_receipt 1; }
      fi
      if [[ -e "$work/previous.app" ]]; then
        mv "$work/previous.app" "$destination" || { echo "Restore failed; lock and recovery pointer retained at $lock" >&2; emit_receipt 1; }
      fi
      if (( had_previous && was_running )); then
        if start_app "$destination" && app_ready "$destination"; then
          echo "Previous app restored and healthy."
        else
          echo "Previous app restored on disk; restart/health failed." >&2
          rollback=restored_unhealthy
        fi
      fi
      if [[ "$rollback" != restored_unhealthy ]]; then rollback=restored; fi
    fi
    release_lock || result=1
    emit_receipt "$result"
  }
  # Serialization owns no install effects. Recovery output survives ordinary failure.
  # shellcheck disable=SC2329
  emit_receipt() {
    local code="$1"
    trap - EXIT
    if [[ "${INSTALL_JSON:-0}" == 1 ]]; then
      python3 "$contract" receipt "$source_app" "$destination" "$work" "$stage" "$rollback" "$code" "$success" >&3 || exit 1
    else
      python3 "$contract" receipt "$source_app" "$destination" "$work" "$stage" "$rollback" "$code" "$success" > /dev/null || exit 1
    fi
    exit "$code"
  }
  trap finish EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  [[ -d "$source_app" && ! -L "$destination" ]] || exit 1
  stage=reserve
  mkdir "$lock" || { echo "Installation already reserved: $lock" >&2; exit 1; }
  lock_owned=1
  printf 'pid=%s\nsource=%s\ndestination=%s\n' "$$" "$source_app" "$destination" > "$lock/owner.txt"
  work="$(mktemp -d "$parent/.$name.install.XXXXXX")"
  printf 'recovery=%s\n' "$work" >> "$lock/owner.txt"
  printf '%s\n' "source=$source_app" "destination=$destination" > "$work/operation.txt"
  # Copy and verify before stopping anything. Rename stays on the same volume.
  stage=copy
  ditto "$source_app" "$work/$name" || exit 1
  stage=verify
  verify_app "$work/$name" || exit 1
  stage=stop
  stop_app "$destination" || exit 1
  stopped=1
  stage=replace
  if (( had_previous )); then mv "$destination" "$work/previous.app" || exit 1; fi
  mv "$work/$name" "$destination" || exit 1
  stage=launch
  start_app "$destination" || exit 1
  stage=health
  app_ready "$destination" || exit 1
  success=1
  stage=complete
  echo "Installed candidate is healthy; previous app retained at $work/previous.app"
)
