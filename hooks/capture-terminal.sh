#!/usr/bin/env bash
# SessionStart hook: report which terminal this session runs in, keyed by session_id.
INPUT=$(cat)
SID=$(printf '%s' "$INPUT" | sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
[ -z "$SID" ] && exit 0
PORT="${VIBEBUDDY_PORT:-9876}"
TTY=$(ps -o tty= -p $$ 2>/dev/null | tr -d ' ')
printf '{"session_id":"%s","term_program":"%s","tty":"%s","tmux":"%s","tmux_pane":"%s"}' \
  "$SID" "${TERM_PROGRAM:-}" "$TTY" "${TMUX:-}" "${TMUX_PANE:-}" \
  | curl -sS --max-time 3 -X POST --data-binary @- "http://127.0.0.1:${PORT}/terminal" 2>/dev/null || true
exit 0
