#!/bin/bash
# vibebuddy Codex notify handler.
# Codex passes the event JSON as the first argument. Forward it to the daemon,
# tagged as codex. Fail-open: never blocks Codex.
#
# Wire it up in ~/.codex/config.toml:
#     notify = ["/Users/example/Projects/iOS-vibebuddy/hooks/codex-notify.sh"]
PAYLOAD="$1"
[ -z "$PAYLOAD" ] && exit 0
curl -sS --max-time 3 -X POST --data-binary "$PAYLOAD" \
  "http://127.0.0.1:${VIBEBUDDY_PORT:-9876}/hook?agent=codex" 2>/dev/null || true
