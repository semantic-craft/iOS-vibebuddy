#!/bin/sh
# Blocking PreToolUse approval forwarder. Reads the hook JSON on stdin, asks the
# local daemon, and echoes its permission decision verbatim. On any failure it
# prints nothing and exits 0 so the agent proceeds with its normal flow.
#
# Usage: approval-hook.sh [source [hold]]
#   no argument  → Claude Code (snake_case envelope, hookSpecificOutput reply);
#                  installers since WR-11 write `claude <hold>` for it
#   grok         → Grok Build  (camelCase envelope, {"decision":…} reply)
# The source is forwarded as `/approval?agent=<source>`; the daemon picks the
# envelope to decode and the decision contract to answer in from it.
#
# hold: how many seconds the daemon may keep this call waiting for the phone
# while nobody is at the Mac. Only an installer that also raised the agent's own
# hook timeout above it passes one (WR-11); without it the daemon keeps its short
# default, so an older config never has its hook killed while the phone still
# shows a live card. Clamped here to the daemon's own 25–120 s, so curl never
# gives up before the daemon does.
SOURCE="$1"
HOLD="$2"
# Grok imports Claude's hooks through [compat.claude] and runs any command that
# has arguments. Only Grok's own gate may ask on its behalf.
[ -n "$GROK_SESSION_ID" ] && [ "$SOURCE" != grok ] && exit 0
PORT="${VIBEBUDDY_PORT:-9876}"
URL="http://127.0.0.1:${PORT}/approval"
[ -n "$SOURCE" ] && URL="${URL}?agent=${SOURCE}"
MAX_TIME=30
case "$HOLD" in ''|*[!0-9]*) HOLD= ;; esac
# Leading zeros would read as octal in $((…)).
while [ -n "$HOLD" ] && [ "${HOLD#0}" != "$HOLD" ]; do HOLD=${HOLD#0}; done
if [ -n "$HOLD" ]; then
  if [ ${#HOLD} -gt 3 ] || [ "$HOLD" -gt 120 ]; then HOLD=120; fi
  [ "$HOLD" -lt 25 ] && HOLD=25
  case "$URL" in *\?*) URL="${URL}&hold=${HOLD}" ;; *) URL="${URL}?hold=${HOLD}" ;; esac
  MAX_TIME=$((HOLD + 10))
fi
# /approval is bearer-token gated (daemon-security/01); read the token at runtime.
# No token → 401 → empty RESP → the agent proceeds with its normal flow (fail-open).
TOKEN_FILE="${VIBEBUDDY_TOKEN_FILE:-$HOME/Library/Application Support/vibebuddy/token}"
TOKEN="${VIBEBUDDY_TOKEN:-$(cat "$TOKEN_FILE" 2>/dev/null)}"
# The header reaches curl through fd 3 (`-H @/dev/fd/3` + here-document), never
# argv, so `ps` cannot show the token. No token → an empty file → no header.
AUTH_HEADER=; [ -n "$TOKEN" ] && AUTH_HEADER="Authorization: Bearer $TOKEN"
RESP=$(curl -sS --max-time "$MAX_TIME" -H @/dev/fd/3 \
  -X POST --data-binary @- "$URL" 2>/dev/null 3<<EOF
$AUTH_HEADER
EOF
)
[ -n "$RESP" ] && printf '%s' "$RESP"
exit 0
