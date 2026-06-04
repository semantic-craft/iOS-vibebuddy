#!/usr/bin/env bash
# Blocking PreToolUse approval forwarder. Reads the hook JSON on stdin, asks the
# local daemon, and echoes its permission decision. On any failure it prints
# nothing and exits 0 so Claude Code proceeds with its normal flow.
PORT="${VIBEBUDDY_PORT:-9876}"
RESP=$(curl -sS --max-time 30 -X POST --data-binary @- "http://127.0.0.1:${PORT}/approval" 2>/dev/null)
[ -n "$RESP" ] && printf '%s' "$RESP"
exit 0
