#!/usr/bin/env bash
# SessionStart hook: report which terminal this session runs in, keyed by session_id.
# Claude Code may run hooks with a stripped env / no controlling tty, so we fall
# back to reading TMUX/TMUX_PANE/TERM_PROGRAM from an ancestor process (the shell
# or `claude` running in the pane) via `ps eww`.
INPUT=$(cat)
SID=$(printf '%s' "$INPUT" | sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
[ -z "$SID" ] && exit 0

# Read $1 from this process's env, else walk up ancestors and read theirs.
read_var() {
  local var="$1" pid depth=0 val
  eval "val=\${$var:-}"
  [ -n "$val" ] && { printf '%s' "$val"; return; }
  pid=$(ps -o ppid= -p "$$" 2>/dev/null | tr -d ' ')
  while [ -n "$pid" ] && [ "$pid" != "0" ] && [ "$pid" != "1" ] && [ "$depth" -lt 8 ]; do
    val=$(ps eww -p "$pid" -o command= 2>/dev/null | tr ' ' '\n' | sed -n "s/^${var}=//p" | head -1)
    [ -n "$val" ] && { printf '%s' "$val"; return; }
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    depth=$((depth + 1))
  done
}

TP=$(read_var TERM_PROGRAM)
TMUXV=$(read_var TMUX)
PANE=$(read_var TMUX_PANE)
TTY=$(ps -o tty= -p $$ 2>/dev/null | tr -d ' ')
{ [ -z "$TTY" ] || [ "$TTY" = "??" ]; } && TTY=$(ps -o tty= -p "$(ps -o ppid= -p $$ | tr -d ' ')" 2>/dev/null | tr -d ' ')

# Inside tmux, TERM_PROGRAM is "tmux"; the real terminal is the one that launched
# the tmux server (its pid is the middle field of $TMUX). Resolve it so the Mac
# can foreground the actual app (e.g. Ghostty), not "tmux".
if [ "$TP" = "tmux" ] && [ -n "$TMUXV" ]; then
  server_pid=$(printf '%s' "$TMUXV" | cut -d, -f2)
  if [ -n "$server_pid" ]; then
    real=$(ps eww -p "$server_pid" -o command= 2>/dev/null | tr ' ' '\n' | sed -n 's/^TERM_PROGRAM=//p' | head -1)
    [ -n "$real" ] && TP="$real"
  fi
fi

# kitty doesn't set TERM_PROGRAM; synthesize it from kitty's own markers so the
# Mac can foreground it (open -a kitty). Other terminals (Warp=WarpTerminal,
# WezTerm=WezTerm) already export TERM_PROGRAM, so no fallback needed for them.
if [ -z "$TP" ]; then
  if [ -n "$(read_var KITTY_WINDOW_ID)" ] || [ "$(read_var TERM)" = "xterm-kitty" ]; then
    TP="kitty"
  fi
fi

PORT="${VIBEBUDDY_PORT:-9876}"
# /terminal is bearer-token gated (daemon-security/01); read the token at runtime.
TOKEN_FILE="${VIBEBUDDY_TOKEN_FILE:-$HOME/Library/Application Support/vibebuddy/token}"
TOKEN="${VIBEBUDDY_TOKEN:-$(cat "$TOKEN_FILE" 2>/dev/null)}"
AUTH=(); [ -n "$TOKEN" ] && AUTH=(-H "Authorization: Bearer $TOKEN")
printf '{"session_id":"%s","term_program":"%s","tty":"%s","tmux":"%s","tmux_pane":"%s"}' \
  "$SID" "$TP" "$TTY" "$TMUXV" "$PANE" \
  | curl -sS --max-time 3 "${AUTH[@]}" -X POST --data-binary @- "http://127.0.0.1:${PORT}/terminal" 2>/dev/null || true
exit 0
