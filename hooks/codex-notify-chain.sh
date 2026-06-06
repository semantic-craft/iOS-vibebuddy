#!/bin/bash
# vibebuddy Codex notify (chaining).
# Codex calls this with the event JSON as the last argument. We (1) preserve the
# existing "Codex Computer Use" notify untouched, then (2) forward the same JSON
# to the vibebuddy daemon, tagged codex. Both are fail-open / non-blocking.
PAYLOAD="$1"

# (1) original Codex Computer Use notify — same invocation as before
ORIG="${CODEX_COMPUTER_USE_NOTIFY:-}"
[ -x "$ORIG" ] && "$ORIG" "turn-ended" "$PAYLOAD" >/dev/null 2>&1 &

# (2) forward to vibebuddy (tagged codex). /hook is bearer-token gated
# (daemon-security/01); read the token at runtime.
TOKEN_FILE="${VIBEBUDDY_TOKEN_FILE:-$HOME/Library/Application Support/vibebuddy/token}"
TOKEN="${VIBEBUDDY_TOKEN:-$(cat "$TOKEN_FILE" 2>/dev/null)}"
AUTH=(); [ -n "$TOKEN" ] && AUTH=(-H "Authorization: Bearer $TOKEN")
[ -n "$PAYLOAD" ] && curl -sS --max-time 3 "${AUTH[@]}" -X POST --data-binary "$PAYLOAD" \
  "http://127.0.0.1:${VIBEBUDDY_PORT:-9876}/hook?agent=codex" 2>/dev/null || true
