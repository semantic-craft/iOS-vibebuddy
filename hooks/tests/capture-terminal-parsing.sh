#!/usr/bin/env bash
# Unit test for the pure helpers in hooks/capture-terminal.sh, plus one
# end-to-end `--print` run. No network, no AppleScript, no process-table
# assumptions: the parsers are fed fixed strings.
#
#   bash hooks/tests/capture-terminal-parsing.sh

HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$HERE/../capture-terminal.sh"

FAILED=0
check() {  # check <name> <expected> <actual>
  if [ "$2" = "$3" ]; then
    printf 'ok   %s\n' "$1"
  else
    printf 'FAIL %s\n       expected: [%s]\n       actual:   [%s]\n' "$1" "$2" "$3"
    FAILED=1
  fi
}

# Source the helpers without running the capture.
VIBEBUDDY_CAPTURE_LIB_ONLY=1 . "$SCRIPT"

# ------------------------------------------------------------- bundle_path
check "Electron helper resolves to the app the user sees" \
  "/Applications/Cursor.app" \
  "$(bundle_path '/Applications/Cursor.app/Contents/Frameworks/Cursor Helper (Plugin).app/Contents/MacOS/Cursor Helper (Plugin)')"

check "a plain GUI executable resolves to its own bundle" \
  "/Applications/Ghostty.app" \
  "$(bundle_path /Applications/Ghostty.app/Contents/MacOS/ghostty)"

check "a bundle path with a space survives" \
  "/Applications/Visual Studio Code.app" \
  "$(bundle_path '/Applications/Visual Studio Code.app/Contents/MacOS/Electron')"

check "a non-GUI executable is not a bundle" "" "$(bundle_path /bin/zsh)"
check "a relative path is not a bundle" "" "$(bundle_path 'Foo.app/Contents/MacOS/Foo')"
check "an .app mentioned outside Contents/MacOS is not a bundle" "" \
  "$(bundle_path /Users/x/notes-about-Cursor.app/readme.txt)"

# ----------------------------------------------------------- gui_bundle_id
# A fake ancestry: an agent CLI shipped as a background-only wrapper .app that
# lives *beside* (not inside) the real GUI app hosting it — the shape of a
# Claude Code desktop session, where the wrapper's bundle id is not activatable
# and the walk has to keep climbing to reach the app the user actually sees.
FIXTURE=$(mktemp -d -t vbcapture-bundles) || exit 1
trap 'rm -rf "$FIXTURE"' EXIT

make_bundle() {  # make_bundle <name> <bundle id> [<extra plist keys XML>]
  mkdir -p "$FIXTURE/$1.app/Contents/MacOS"
  cat >"$FIXTURE/$1.app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>$2</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  ${3:-}
</dict></plist>
PLIST
  printf '%s' "$FIXTURE/$1.app/Contents/MacOS/$1"
}

WRAPPER=$(make_bundle wrapper com.example.wrapper '<key>LSBackgroundOnly</key><true/>')
AGENT=$(make_bundle agent com.example.agent '<key>LSUIElement</key><string>YES</string>')
HOST=$(make_bundle host com.example.host)

check "a background-only bundle is not a jumpable host" "" "$(gui_bundle_id "$WRAPPER")"
check "an LSUIElement bundle is not a jumpable host either" "" "$(gui_bundle_id "$AGENT")"
check "a plain foreground bundle is" "com.example.host" "$(gui_bundle_id "$HOST")"
check "an executable outside any bundle is not" "" "$(gui_bundle_id /bin/zsh)"

# The ancestor walk itself: nearest first, first non-empty id wins.
WALK=""
for exe in "$WRAPPER" "/usr/bin/some-helper" "$HOST"; do
  [ -n "$WALK" ] && continue
  WALK=$(gui_bundle_id "$exe")
done
check "the walk skips the background-only wrapper and picks the GUI host" \
  "com.example.host" "$WALK"

check "plist_true accepts 1" "true" "$(plist_true 1 && echo true)"
check "plist_true accepts YES and true" "true" "$(plist_true YES && plist_true true && echo true)"
check "plist_true rejects 0 and an absent value" "" "$(plist_true 0 || plist_true '' || true)"

# ------------------------------------------------------------- env_extract
PS_LINE='/bin/zsh -l TERM_PROGRAM=ghostty TMUX=/Volumes/My Disk/tmux-501/default,1234,0 TMUX_PANE=%3 TERM=xterm-ghostty'
check "a value containing spaces is not truncated" \
  "TMUX=/Volumes/My Disk/tmux-501/default,1234,0" \
  "$(printf '%s\n' "$PS_LINE" | env_extract TMUX)"

check "each wanted variable is extracted, argv left alone" \
  "TERM_PROGRAM=ghostty
TMUX_PANE=%3" \
  "$(printf '%s\n' "$PS_LINE" | env_extract TERM_PROGRAM TMUX_PANE)"

check "an argv token that looks like an assignment is not a variable" "" \
  "$(printf '%s\n' '/usr/bin/foo --term_program=bar --x=1' | env_extract TERM_PROGRAM)"

check "the nearest ancestor's value wins" \
  "TERM_PROGRAM=ghostty" \
  "$(printf '%s\n%s\n' 'a TERM_PROGRAM=ghostty' 'b TERM_PROGRAM=iTerm.app' | env_extract TERM_PROGRAM)"

check "a value containing = survives (KITTY_LISTEN_ON)" \
  "KITTY_LISTEN_ON=unix:/tmp/k=1" \
  "$(printf '%s\n' 'kitty KITTY_LISTEN_ON=unix:/tmp/k=1 TERM=xterm-kitty' | env_extract KITTY_LISTEN_ON)"

check "nothing is printed for a variable that isn't set" "" \
  "$(printf '%s\n' '/bin/zsh TERM=xterm' | env_extract WEZTERM_PANE)"

# --------------------------------------------------------------------- add
JSON=""; add cwd '/Users/x/a"b\c'
check "a quote and a backslash are escaped, not dropped" \
  ',"cwd":"/Users/x/a\"b\\c"' "$JSON"

JSON=""; add tty "$(printf 'ttys003\nrogue')"
check "a newline is stripped so the JSON stays valid" ',"tty":"ttys003rogue"' "$JSON"

JSON=""; add term_program "$(printf 'ghos\ttty')"
check "a tab is stripped too" ',"term_program":"ghostty"' "$JSON"

JSON=""; add cwd "$(printf '\001\002')"
check "a value that was nothing but control characters is omitted" "" "$JSON"

JSON=""; add tty ""
check "an empty value is omitted" "" "$JSON"

JSON=""; add_num host_pid 4242; add_num host_pid_bad "12a"; add_num host_pid_empty ""
check "add_num takes digits and refuses anything else" ',"host_pid":4242' "$JSON"

# --------------------------------------------------------- end-to-end shape
BODY=$(echo '{"session_id":"probe-test","cwd":"/tmp"}' | VIBEBUDDY_GHOSTTY_PROBE=0 bash "$SCRIPT" --print)
case "$BODY" in
  '{"session_id":"probe-test"'*'"cwd":"/tmp"}') printf 'ok   %s\n' "--print emits one JSON object for the given session" ;;
  *) printf 'FAIL %s\n       actual: [%s]\n' "--print emits one JSON object for the given session" "$BODY"; FAILED=1 ;;
esac
LINES=$(printf '%s\n' "$BODY" | wc -l | tr -d ' ')
check "--print output is a single line" "1" "$LINES"
if command -v python3 >/dev/null 2>&1; then
  if printf '%s' "$BODY" | python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null; then
    printf 'ok   %s\n' "--print output parses as JSON"
  else
    printf 'FAIL %s\n       actual: [%s]\n' "--print output parses as JSON" "$BODY"; FAILED=1
  fi
else
  printf 'skip %s (no python3)\n' "--print output parses as JSON"
fi

if [ "$FAILED" = "0" ]; then
  echo "PASS: capture-terminal.sh parsing"
else
  echo "FAIL: capture-terminal.sh parsing"
fi
exit "$FAILED"
