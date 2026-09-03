#!/usr/bin/env bash
# SessionStart hook: report *where* this agent session lives, keyed by session_id,
# so the Mac app can jump back to it.
#
# Three levels of precision are captured, because that is how much the host is
# willing to tell us:
#   pane    — $TMUX_PANE inside a multiplexer
#   surface — the tty, $ITERM_SESSION_ID, $WEZTERM_PANE, $KITTY_WINDOW_ID, or
#             Ghostty's terminal id: one window/tab/split of one emulator
#   app     — $TERM_PROGRAM, and the bundle id of the nearest *foreground* GUI
#             ancestor process, which is the only handle an embedded terminal
#             (the Claude desktop app, Cursor, Zed, a JetBrains IDE) ever gives
#             us. Background-only wrapper bundles in between are skipped.
#
# Agents run hooks with a stripped env and no controlling tty, so almost nothing
# is readable from this process: the environment, the tty and the host app all
# come from walking up the process tree. That walk is done once, from a single
# `ps` snapshot, plus one short `ps` per ancestor for its environment and
# executable path — a couple of dozen in the worst case, well under 100 ms.
#
# Dry run: `VIBEBUDDY_CAPTURE_DRY_RUN=1 bash capture-terminal.sh` (or `--print`)
# prints the JSON instead of POSTing it.
#
# Deliberately not `set -e`/`set -u`: a hook must never fail the session it is
# reporting on, and `"${AUTH[@]}"` on an empty array is an error under `set -u`
# in the bash 3.2 that ships with macOS.

# --------------------------------------------------------------------- helpers
# Everything above the library guard below reads no globals and touches nothing
# but the Info.plist files it is handed. `hooks/tests/capture-terminal-parsing.sh`
# sources this file with VIBEBUDDY_CAPTURE_LIB_ONLY=1 to exercise these directly.

# The .app bundle an executable lives in, or nothing when it isn't in one.
# Cuts at the *first* ".app/", which is what makes an Electron helper
# (/Applications/Cursor.app/Contents/Frameworks/Cursor Helper (Plugin).app/...)
# resolve to the app the user actually sees rather than to the helper bundle.
bundle_path() {  # bundle_path <executable path>
  case "$1" in
    /*.app/Contents/MacOS/*) printf '%s' "${1%%.app/*}.app" ;;
  esac
}

# True when a value read out of an Info.plist means yes. `defaults read` prints
# 1 for a real boolean; some bundles still ship the string forms.
plist_true() {  # plist_true <value>
  case "$1" in
    1 | true | TRUE | True | YES | Yes | yes) return 0 ;;
  esac
  return 1
}

# The bundle id of the .app an executable lives in, but only when that app can
# actually be brought to the front. A background-only bundle (LSBackgroundOnly
# or LSUIElement) never appears in NSRunningApplication's activatable set, so
# recording it makes the jump a no-op: the Claude Code CLI ships as exactly such
# a wrapper .app (com.anthropic.claude-code) nested inside the Claude desktop
# app, and the ancestor walk has to step over it to reach the real GUI host
# (com.anthropic.claudefordesktop). Prints nothing when the executable is not in
# a bundle, the bundle has no identifier, or the bundle is background-only.
gui_bundle_id() {  # gui_bundle_id <executable path>
  local bundle plist id
  bundle=$(bundle_path "$1")
  [ -n "$bundle" ] || return 0
  plist="$bundle/Contents/Info"
  [ -f "$plist.plist" ] || return 0
  plist_true "$(defaults read "$plist" LSBackgroundOnly 2>/dev/null)" && return 0
  plist_true "$(defaults read "$plist" LSUIElement 2>/dev/null)" && return 0
  id=$(defaults read "$plist" CFBundleIdentifier 2>/dev/null)
  [ -n "$id" ] || return 0
  printf '%s' "$id"
}

# Pull wanted variables out of `ps eww` output on stdin, printing `NAME=value`
# for the first occurrence of each. macOS `ps` appends the environment to the
# command line with no delimiter and offers no machine-readable alternative
# (`-E`/`e` is this same concatenated form), so a value is everything up to the
# next ` NAME=` token: splitting on whitespace would truncate
# `TMUX=/Volumes/My Disk/tmux-501/default,1,0` and would happily mistake an
# argv token such as `--foo=bar` for a variable.
env_extract() {  # env_extract <NAME>...
  awk -v wanted="$*" '
    BEGIN { n = split(wanted, names, " "); for (i = 1; i <= n; i++) want[names[i]] = 1 }
    {
      line = " " $0
      while (match(line, / [A-Z_][A-Z0-9_]*=/)) {
        k = substr(line, RSTART + 1, RLENGTH - 2)
        line = substr(line, RSTART + RLENGTH)
        if (match(line, / [A-Z_][A-Z0-9_]*=/)) v = substr(line, 1, RSTART - 1)
        else v = line
        if (want[k] && !(k in seen)) { seen[k] = 1; print k "=" v }
      }
    }'
}

JSON=""
add() {  # add <key> <string value> — omitted entirely when empty
  [ -n "${2:-}" ] || return 0
  local escaped
  # Control characters are stripped, not escaped: a raw newline or tab inside a
  # JSON string is invalid, and the server drops the whole payload without a
  # word. None of the values we send (paths, ids, $TERM_PROGRAM) can legitimately
  # contain one. Backslash first, so the quote escape isn't re-escaped.
  escaped=$(printf '%s' "$2" | tr -d '[:cntrl:]' | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')
  [ -n "$escaped" ] || return 0
  JSON="$JSON,\"$1\":\"$escaped\""
}
add_num() {  # add_num <key> <integer value> — non-digits are dropped
  case "${2:-}" in
    "" | *[!0-9]*) return 0 ;;
  esac
  JSON="$JSON,\"$1\":$2"
}

# Sourced by hooks/tests/ to reach the helpers above; everything below has side
# effects (reads stdin, walks the process table, POSTs).
if [ "${VIBEBUDDY_CAPTURE_LIB_ONLY:-0}" = "1" ]; then
  return 0 2>/dev/null || exit 0
fi

DRY_RUN=0
[ "${VIBEBUDDY_CAPTURE_DRY_RUN:-0}" = "1" ] && DRY_RUN=1
[ "${1:-}" = "--print" ] && DRY_RUN=1

# The hook payload arrives on stdin. Don't block on an interactive terminal, so
# the dry run can be invoked by hand.
INPUT=""
[ -t 0 ] || INPUT=$(cat)

json_str() {  # json_str <key>  — first string value of "key" in $INPUT
  printf '%s' "$INPUT" \
    | sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" | head -1
}

# Claude/Codex/Qwen/Kimi/OpenCode send `session_id`; the Grok CLI sends `sessionId`.
SID=$(json_str session_id)
[ -z "$SID" ] && SID=$(json_str sessionId)
EVENT=$(json_str hook_event_name)
CWD=$(json_str cwd)
[ -z "$CWD" ] && CWD="$PWD"
if [ -z "$SID" ] && [ "$DRY_RUN" = "0" ]; then exit 0; fi

# ---------------------------------------------------------------- ancestor walk
# One snapshot of the process table, then climb it in awk: pid, tty and full
# command for this process and each ancestor, nearest first.
CHAIN=$(ps -Awwo pid=,ppid=,tty=,command= 2>/dev/null | awk -v start="$$" '
  {
    parent[$1] = $2; term[$1] = $3
    c = ""
    for (i = 4; i <= NF; i++) c = c (i > 4 ? " " : "") $i
    cmd[$1] = c
  }
  END {
    p = start; n = 0
    while (p != "" && p != "0" && p != "1" && n < 12) {
      if (!(p in parent)) break
      printf "%s\t%s\t%s\n", p, term[p], cmd[p]
      p = parent[p]; n++
    }
  }')

PIDS=""
TTY=""
HOST_BUNDLE=""
HOST_PID=""
while IFS=$'\t' read -r pid ptty _pcmd; do
  [ -n "$pid" ] || continue
  PIDS="$PIDS $pid"
  # First ancestor that still owns a terminal. Hook processes never do.
  if [ -z "$TTY" ] && [ -n "$ptty" ] && [ "$ptty" != "??" ] && [ "$ptty" != "?" ]; then
    TTY="$ptty"
  fi
  # First ancestor that is a GUI app the user can actually be sent to. Matched
  # against `comm` — the executable path alone — rather than the full command
  # line, so an argument that merely mentions an .app path can't be mistaken for
  # the host, and background-only bundles are walked past (see gui_bundle_id).
  if [ -z "$HOST_BUNDLE" ]; then
    id=$(gui_bundle_id "$(ps -o comm= -p "$pid" 2>/dev/null)")
    if [ -n "$id" ]; then HOST_BUNDLE="$id"; HOST_PID="$pid"; fi
  fi
done <<EOF
$CHAIN
EOF

# ------------------------------------------------------------------ environment
# `ps eww` prints a process's environment after its command line. Collect this
# process's env and every ancestor's in one pass and keep the nearest value of
# each variable we care about.
env_dump() {
  for pid in $PIDS; do
    ps eww -p "$pid" -o command= 2>/dev/null
  done
}

TERM_PROGRAM_V=""; TMUX_V=""; TMUX_PANE_V=""; ITERM_V=""
WEZTERM_V=""; KITTY_WINDOW_V=""; KITTY_LISTEN_V=""; TERM_V=""
WANTED="TERM_PROGRAM TMUX TMUX_PANE ITERM_SESSION_ID WEZTERM_PANE KITTY_WINDOW_ID KITTY_LISTEN_ON TERM"
# `read -r key value` splits on the first `=` only, so a value containing one
# (`$TMUX` never does, `$KITTY_LISTEN_ON` can) survives intact.
while IFS='=' read -r key value; do
  case "$key" in
    TERM_PROGRAM)     TERM_PROGRAM_V="$value" ;;
    TMUX)             TMUX_V="$value" ;;
    TMUX_PANE)        TMUX_PANE_V="$value" ;;
    ITERM_SESSION_ID) ITERM_V="$value" ;;
    WEZTERM_PANE)     WEZTERM_V="$value" ;;
    KITTY_WINDOW_ID)  KITTY_WINDOW_V="$value" ;;
    KITTY_LISTEN_ON)  KITTY_LISTEN_V="$value" ;;
    TERM)             TERM_V="$value" ;;
  esac
done <<EOF
$(env_dump | env_extract $WANTED)
EOF

# Inside tmux, TERM_PROGRAM is "tmux"; the real terminal is the one that started
# the tmux server (its pid is the middle field of $TMUX). Resolve it so the Mac
# foregrounds the actual app rather than the multiplexer.
if [ "$TERM_PROGRAM_V" = "tmux" ] && [ -n "$TMUX_V" ]; then
  server_pid=$(printf '%s' "$TMUX_V" | cut -d, -f2)
  if [ -n "$server_pid" ]; then
    real=$(ps eww -p "$server_pid" -o command= 2>/dev/null \
      | env_extract TERM_PROGRAM | sed -n 's/^TERM_PROGRAM=//p' | head -1)
    [ -n "$real" ] && TERM_PROGRAM_V="$real"
  fi
fi

# kitty sets no TERM_PROGRAM; synthesize it from kitty's own markers. Warp
# (WarpTerminal) and WezTerm both export one, so they need no fallback.
if [ -z "$TERM_PROGRAM_V" ]; then
  if [ -n "$KITTY_WINDOW_V" ] || [ "$TERM_V" = "xterm-kitty" ]; then
    TERM_PROGRAM_V="kitty"
  fi
fi

# $ITERM_SESSION_ID is "w0t0p0:UUID"; only the UUID half matches an iTerm2
# session's `unique ID`.
ITERM_SESSION_ID="${ITERM_V##*:}"

# ------------------------------------------------------------- Ghostty terminal
# Ghostty exports no identifier for the surface, so ask it — while this session
# is still the focused one, which is only true at SessionStart. AppleScript to
# another app needs Automation permission, and the very first attempt blocks on
# the system's consent dialog, so the call is hard-capped at 2 s. Once granted it
# costs ~50-150 ms; it is skipped on every later event, and with
# VIBEBUDDY_GHOSTTY_PROBE=0.
run_with_timeout() {  # run_with_timeout <seconds> <command...>
  local secs="$1"; shift
  local out; out=$(mktemp -t vbcapture) || return 1
  "$@" >"$out" 2>/dev/null &
  local child=$!
  ( sleep "$secs"; kill -9 "$child" 2>/dev/null ) >/dev/null 2>&1 &
  local watchdog=$!
  wait "$child" 2>/dev/null
  kill "$watchdog" 2>/dev/null
  wait "$watchdog" 2>/dev/null
  head -1 "$out"
  rm -f "$out"
}

GHOSTTY_TERMINAL_ID=""
if [ "$TERM_PROGRAM_V" = "ghostty" ] && [ "${VIBEBUDDY_GHOSTTY_PROBE:-1}" != "0" ] \
   && { [ "$EVENT" = "SessionStart" ] || [ "$DRY_RUN" = "1" ]; }; then
  # Dictionary shape (verified against `sdef /Applications/Ghostty.app`):
  # application → `front window` (window) → `selected tab` (tab) →
  # `focused terminal` (terminal) → `id` (text). Addressed by bundle id so the
  # "Where is Ghostty?" chooser can never appear, and matching the jumper's
  # `tell application id "com.mitchellh.ghostty"`.
  GHOSTTY_TERMINAL_ID=$(run_with_timeout 2 /usr/bin/osascript -e \
    'tell application id "com.mitchellh.ghostty" to return id of focused terminal of selected tab of front window')
fi

# ------------------------------------------------------------------------- POST
add session_id "$SID"
add term_program "$TERM_PROGRAM_V"
add tty "$TTY"
add tmux "$TMUX_V"
add tmux_pane "$TMUX_PANE_V"
add iterm_session_id "$ITERM_SESSION_ID"
add wezterm_pane "$WEZTERM_V"
add kitty_window_id "$KITTY_WINDOW_V"
add kitty_listen_on "$KITTY_LISTEN_V"
add ghostty_terminal_id "$GHOSTTY_TERMINAL_ID"
add host_bundle_id "$HOST_BUNDLE"
add_num host_pid "$HOST_PID"
add cwd "$CWD"
BODY="{${JSON#,}}"

if [ "$DRY_RUN" = "1" ]; then
  printf '%s\n' "$BODY"
  exit 0
fi

PORT="${VIBEBUDDY_PORT:-9876}"
# /terminal is bearer-token gated (daemon-security/01); read the token at runtime.
TOKEN_FILE="${VIBEBUDDY_TOKEN_FILE:-$HOME/Library/Application Support/vibebuddy/token}"
TOKEN="${VIBEBUDDY_TOKEN:-$(cat "$TOKEN_FILE" 2>/dev/null)}"
AUTH=(); [ -n "$TOKEN" ] && AUTH=(-H "Authorization: Bearer $TOKEN")
printf '%s' "$BODY" \
  | curl -sS --max-time 3 "${AUTH[@]}" -X POST --data-binary @- \
      "http://127.0.0.1:${PORT}/terminal" >/dev/null 2>&1 || true
exit 0
