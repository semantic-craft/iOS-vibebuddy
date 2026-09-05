#!/bin/sh
# Claude Code status line wrapper. Claude runs the configured status line
# command on every event with a JSON document on stdin (context, cost, session
# name, effort, PR, worktree, rate limits). This script copies that document to
# the local vibebuddy daemon in the background, fail-open, then hands the very
# same input to the status line command that was configured before vibebuddy
# was installed and prints its output — so what the terminal shows never
# changes. With no original command, it prints nothing.
#
# The original command lives in a plain file next to the daemon token
# (install-claude-hooks.py writes it; --uninstall restores it), so this script
# never parses JSON and costs one fork beyond the original.
INPUT=$(cat)
PORT="${VIBEBUDDY_PORT:-9876}"
SUPPORT="${VIBEBUDDY_SUPPORT_DIR:-$HOME/Library/Application Support/vibebuddy}"
TOKEN_FILE="${VIBEBUDDY_TOKEN_FILE:-$SUPPORT/token}"
TOKEN="${VIBEBUDDY_TOKEN:-$(cat "$TOKEN_FILE" 2>/dev/null)}"
if [ -n "$TOKEN" ]; then
  # Detached: the daemon must never delay Claude's own status line render.
  ( printf '%s' "$INPUT" | curl -sS --max-time 1 -H "Authorization: Bearer $TOKEN" \
      -X POST --data-binary @- "http://127.0.0.1:${PORT}/statusline" >/dev/null 2>&1 ) &
fi
ORIGINAL_FILE="${VIBEBUDDY_STATUSLINE_ORIGINAL:-$SUPPORT/statusline-original.cmd}"
if [ -s "$ORIGINAL_FILE" ]; then
  ORIGINAL=$(cat "$ORIGINAL_FILE")
  [ -n "$ORIGINAL" ] && printf '%s' "$INPUT" | /bin/sh -c "$ORIGINAL"
fi
exit 0
