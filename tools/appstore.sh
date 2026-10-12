#!/usr/bin/env bash
# Explicit launch entry: load only the ASC whitelist, never a login shell.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
for arg in "$@"; do
  case "$arg" in -h|--help) exec python3 "$REPO/tools/appstore.py" "$@" ;; esac
done
case "${1:-}" in
  plan|-h|--help|"") exec python3 "$REPO/tools/appstore.py" "$@" ;;
esac
case "${1:-}" in
  upload|stage|submit)
    confirmed=0
    for arg in "$@"; do [[ "$arg" != --confirm ]] || confirmed=1; done
    if (( ! confirmed )); then exec python3 "$REPO/tools/appstore.py" "$@"; fi
    ;;
esac
case "${1:-}" in
  status) credentials=(ASC_STATUS_KEY_ID ASC_STATUS_ISSUER_ID ASC_STATUS_PRIVATE_KEY_B64) ;;
  upload|stage|submit) credentials=(ASC_KEY_ID ASC_ISSUER_ID ASC_PRIVATE_KEY_B64) ;;
  *) exec python3 "$REPO/tools/appstore.py" "$@" ;;
esac
log_error() { printf '%s\n' "$*" >&2; }
LOADER="$HOME/.config/direnv/lib/helios-secrets.sh"
[[ -f "$LOADER" ]] || { log_error "Missing helios secrets loader: $LOADER"; exit 1; }
source "$LOADER"
for name in "${!ASC_@}"; do unset "$name"; done
use_secrets "${credentials[@]}"
exec python3 "$REPO/tools/appstore.py" "$@"
