#!/usr/bin/env bash
# Blocking PreToolUse approval forwarder. Reads the hook JSON on stdin, asks the
# local daemon, and echoes its permission decision. On any failure it prints
# nothing and exits 0 so Claude Code proceeds with its normal flow.
PORT="${VIBEBUDDY_PORT:-9876}"
# /approval is bearer-token gated (daemon-security/01); read the token at runtime.
# No token → 401 → empty RESP → Claude proceeds with its normal flow (fail-open).
TOKEN_FILE="${VIBEBUDDY_TOKEN_FILE:-$HOME/Library/Application Support/vibebuddy/token}"
TOKEN="${VIBEBUDDY_TOKEN:-$(cat "$TOKEN_FILE" 2>/dev/null)}"
AUTH=(); [ -n "$TOKEN" ] && AUTH=(-H "Authorization: Bearer $TOKEN")
RESP=$(curl -sS --max-time 30 "${AUTH[@]}" -X POST --data-binary @- "http://127.0.0.1:${PORT}/approval" 2>/dev/null)
[ -n "$RESP" ] && printf '%s' "$RESP"
exit 0
