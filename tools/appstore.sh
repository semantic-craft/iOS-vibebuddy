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
log_error() { printf '%s\n' "$*" >&2; }
LOADER="$HOME/.config/direnv/lib/helios-secrets.sh"
[[ -f "$LOADER" ]] || { log_error "Missing helios secrets loader: $LOADER"; exit 1; }
source "$LOADER"
unset ASC_KEY_ID ASC_ISSUER_ID ASC_PRIVATE_KEY_B64
use_secrets ASC_KEY_ID ASC_ISSUER_ID ASC_PRIVATE_KEY_B64
exec python3 "$REPO/tools/appstore.py" "$@"
