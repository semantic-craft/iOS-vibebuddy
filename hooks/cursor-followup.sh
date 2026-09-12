#!/usr/bin/env bash
# Cursor `stop` hook: report the ending, then hand Cursor whatever the phone
# queued for this conversation while the turn was running.
#
# Cursor cannot be steered mid-turn — there is no socket, no interrupt, and
# `updated_input` only rewrites a tool call. What it does have is documented
# auto-continuation: a `stop` hook may answer `{"followup_message": "…"}` and
# Cursor submits that as the next message. So this one hook does both jobs of the
# turn's end: forward the lifecycle event, then collect the queued follow-up.
#
# Two requests rather than one because the two answers are different: the status
# POST's body must never reach Cursor's stdout (it would be read as hook output),
# and the follow-up response must be printed verbatim.
#
# Fail-open throughout: no daemon, no token, no queued message, or any error at
# all prints nothing and exits 0, which is exactly how Cursor ends a turn with no
# hook installed.
SOURCE=cursor
PORT="${VIBEBUDDY_PORT:-9876}"
INPUT=""
[ -t 0 ] || INPUT=$(cat)

TOKEN_FILE="${VIBEBUDDY_TOKEN_FILE:-$HOME/Library/Application Support/vibebuddy/token}"
TOKEN="${VIBEBUDDY_TOKEN:-$(cat "$TOKEN_FILE" 2>/dev/null)}"
AUTH=(); [ -n "$TOKEN" ] && AUTH=(-H "Authorization: Bearer $TOKEN")

# 1. The ending itself — fire and forget, output discarded.
printf '%s' "$INPUT" | curl -sS --connect-timeout 1 --max-time 3 -o /dev/null \
  "${AUTH[@]}" -X POST --data-binary @- \
  "http://127.0.0.1:${PORT}/hook?agent=${SOURCE}" 2>/dev/null || true

# 2. The queued follow-up, printed verbatim. An empty body prints nothing.
RESP=$(printf '%s' "$INPUT" | curl -sS --connect-timeout 1 --max-time 5 \
  "${AUTH[@]}" -X POST --data-binary @- \
  "http://127.0.0.1:${PORT}/cursor-followup" 2>/dev/null)
case "$RESP" in
  *followup_message*) printf '%s' "$RESP" ;;
esac
exit 0
