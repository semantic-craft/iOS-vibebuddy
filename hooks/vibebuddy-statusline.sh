#!/bin/sh
# Status line wrapper for Claude Code and Grok Build. The CLI runs the
# configured status line command on every state change with a JSON document on
# stdin (context, cost, session name, effort, worktree; Claude adds PR and rate
# limits). This script copies that document to the local vibebuddy daemon,
# fail-open, then hands the very same input to the status line command that was
# configured before vibebuddy was installed and prints its output — so what the
# terminal shows never changes. With no original command, it prints nothing.
#
# The original command lives in a plain file next to the daemon token
# (the Mac app's HookInstaller writes it; uninstall restores it), so this
# script never parses JSON and costs one fork beyond the original.
#
# Recursion guard: a wrapper that ends up running itself — a saved original
# naming this script, or two wrappers chained — would fork until the machine
# runs out of processes. A nested run forwards nothing and prints nothing.
[ -n "$VIBEBUDDY_STATUSLINE_ACTIVE" ] && exit 0
export VIBEBUDDY_STATUSLINE_ACTIVE=1
# `grok` first: installed into Grok's [ui.status_line]; otherwise Claude.
AGENT=claude
if [ "$1" = grok ]; then AGENT=grok; shift; fi
INPUT=$(cat)
PORT="${VIBEBUDDY_PORT:-9876}"
SUPPORT="${VIBEBUDDY_SUPPORT_DIR:-$HOME/Library/Application Support/vibebuddy}"
TOKEN_FILE="${VIBEBUDDY_TOKEN_FILE:-$SUPPORT/token}"
TOKEN="${VIBEBUDDY_TOKEN:-$(cat "$TOKEN_FILE" 2>/dev/null)}"
FORWARD=
if [ -n "$TOKEN" ]; then
  if [ "$AGENT" = grok ]; then ROUTE="statusline?agent=grok"; else ROUTE=statusline; fi
  # In the background: the daemon must never delay the CLI's own render.
  # The header reaches curl through fd 3, never argv: Grok runs this every few
  # hundred ms, and `ps` would show the token for the whole forward.
  ( printf '%s' "$INPUT" | curl -sS --max-time 1 -H @/dev/fd/3 \
      -X POST --data-binary @- "http://127.0.0.1:${PORT}/${ROUTE}" >/dev/null 2>&1 3<<EOF
Authorization: Bearer $TOKEN
EOF
  ) &
  FORWARD=$!
fi
# `$1` is the installer's key for the config this wrapper was installed into,
# so each Claude directory / Grok home runs its own saved original. No key (a
# Claude install from before C-1) reads the unkeyed file that belonged to
# ~/.claude.
if [ "$AGENT" = grok ]; then
  case "$1" in
    ''|*[!0-9a-f]*) ORIGINAL_DEFAULT= ;;
    *) ORIGINAL_DEFAULT="$SUPPORT/grok-statusline-original.$1.cmd" ;;
  esac
else
  case "$1" in
    ''|*[!0-9a-f]*) ORIGINAL_DEFAULT="$SUPPORT/statusline-original.cmd" ;;
    *) ORIGINAL_DEFAULT="$SUPPORT/statusline-original.$1.cmd" ;;
  esac
fi
ORIGINAL_FILE="${VIBEBUDDY_STATUSLINE_ORIGINAL:-$ORIGINAL_DEFAULT}"
if [ -n "$ORIGINAL_FILE" ] && [ -s "$ORIGINAL_FILE" ]; then
  ORIGINAL=$(cat "$ORIGINAL_FILE")
  case "$ORIGINAL" in *vibebuddy-statusline.sh*) ORIGINAL= ;; esac
  if [ -n "$ORIGINAL" ]; then
    # Grok runs a command that names an executable directly (spaces and
    # all, `~/` expanded) and anything else through `sh -c`; do the same.
    EXECUTABLE=
    if [ "$AGENT" = grok ]; then
      case "$ORIGINAL" in "~/"*) EXECUTABLE="$HOME/${ORIGINAL#\~/}" ;; *) EXECUTABLE="$ORIGINAL" ;; esac
      [ -f "$EXECUTABLE" ] && [ -x "$EXECUTABLE" ] || EXECUTABLE=
    fi
    # Grok ends its payload with a newline (`read -r line` works); Claude
    # does not, and `$(cat)` dropped it either way.
    if [ "$AGENT" = grok ]; then NL='\n'; else NL=; fi
    if [ -n "$EXECUTABLE" ]; then
      printf "%s$NL" "$INPUT" | "$EXECUTABLE"
    else
      printf "%s$NL" "$INPUT" | /bin/sh -c "$ORIGINAL"
    fi
  fi
fi
# Grok kills whatever a status line run leaves behind, so the forward must
# finish (it is bounded at 1 s) before this script exits. Claude lets it go.
[ "$AGENT" = grok ] && [ -n "$FORWARD" ] && wait "$FORWARD"
exit 0
