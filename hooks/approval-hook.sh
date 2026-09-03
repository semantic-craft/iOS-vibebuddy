#!/bin/sh
# Blocking PreToolUse approval forwarder. Reads the hook JSON on stdin, asks the
# local daemon, and echoes its permission decision verbatim. On any failure it
# prints nothing and exits 0 so the agent proceeds with its normal flow.
#
# Usage: approval-hook.sh [source]
#   no argument  → Claude Code (snake_case envelope, hookSpecificOutput reply)
#   grok         → Grok Build  (camelCase envelope, {"decision":…} reply)
# The source is forwarded as `/approval?agent=<source>`; the daemon picks the
# envelope to decode and the decision contract to answer in from it.
SOURCE="$1"
PORT="${VIBEBUDDY_PORT:-9876}"
URL="http://127.0.0.1:${PORT}/approval"
[ -n "$SOURCE" ] && URL="${URL}?agent=${SOURCE}"
# /approval is bearer-token gated (daemon-security/01); read the token at runtime.
# No token → 401 → empty RESP → the agent proceeds with its normal flow (fail-open).
TOKEN_FILE="${VIBEBUDDY_TOKEN_FILE:-$HOME/Library/Application Support/vibebuddy/token}"
TOKEN="${VIBEBUDDY_TOKEN:-$(cat "$TOKEN_FILE" 2>/dev/null)}"
if [ -n "$TOKEN" ]; then
  RESP=$(curl -sS --max-time 30 -H "Authorization: Bearer $TOKEN" \
    -X POST --data-binary @- "$URL" 2>/dev/null)
else
  RESP=$(curl -sS --max-time 30 -X POST --data-binary @- "$URL" 2>/dev/null)
fi
[ -n "$RESP" ] && printf '%s' "$RESP"
exit 0
