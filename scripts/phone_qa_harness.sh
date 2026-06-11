#!/usr/bin/env bash
set -euo pipefail

BASE_URL="${VIBEBUDDY_URL:-http://127.0.0.1:9876}"
TOKEN_FILE="${VIBEBUDDY_TOKEN_FILE:-$HOME/Library/Application Support/vibebuddy/token}"
STATE_DIR="${VIBEBUDDY_QA_STATE_DIR:-/tmp/vibebuddy-phone-qa}"
TMUX_PREFIX="${VIBEBUDDY_QA_TMUX_PREFIX:-vb-phone-qa}"
PROJECT_DIR="${VIBEBUDDY_QA_PROJECT_DIR:-$PWD}"

usage() {
  cat <<'USAGE'
Usage:
  scripts/phone_qa_harness.sh setup-questions
  scripts/phone_qa_harness.sh start-approval
  scripts/phone_qa_harness.sh watch
  scripts/phone_qa_harness.sh cleanup

setup-questions creates two live phone QA sessions:
  - vbqa-option: tap the option button on iPhone.
  - vbqa-manual: type the shown shell command on iPhone and submit.

start-approval starts one blocking approval request. Open the iPhone dashboard
first, then run this command and tap Approve or Deny within 25 seconds.
USAGE
}

require() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "missing required command: $1" >&2
    exit 1
  }
}

token() {
  if [[ ! -r "$TOKEN_FILE" ]]; then
    echo "missing vibebuddy token file: $TOKEN_FILE" >&2
    exit 1
  fi
  tr -d '\n\r' < "$TOKEN_FILE"
}

auth_header() {
  printf 'Authorization: Bearer %s' "$(token)"
}

post_authed_json() {
  local path="$1"
  local body="$2"
  curl -fsS -X POST "$BASE_URL/$path" \
    -H "$(auth_header)" \
    -H 'Content-Type: application/json' \
    --data-binary "$body" >/dev/null
}

healthcheck() {
  curl -fsS "$BASE_URL/health" >/dev/null
}

tmux_path() {
  for p in /opt/homebrew/bin/tmux /usr/local/bin/tmux /usr/bin/tmux; do
    [[ -x "$p" ]] && { printf '%s\n' "$p"; return; }
  done
  printf 'tmux\n'
}

json_string() {
  python3 -c 'import json, sys; print(json.dumps(sys.argv[1]))' "$1"
}

create_tmux_session() {
  local name="$1"
  local tmux
  tmux="$(tmux_path)"
  "$tmux" kill-session -t "$name" >/dev/null 2>&1 || true
  "$tmux" new-session -d -s "$name" -c "$PROJECT_DIR"
  "$tmux" display-message -p -t "$name" '#{pane_id}'
}

tmux_socket() {
  local name="$1"
  "$(tmux_path)" display-message -p -t "$name" '#{socket_path}'
}

register_terminal() {
  local session_id="$1"
  local tmux_name="$2"
  local pane="$3"
  local socket
  socket="$(tmux_socket "$tmux_name")"
  post_authed_json "terminal" "$(python3 - "$session_id" "$socket" "$pane" <<'PY'
import json, sys
session_id, socket, pane = sys.argv[1:]
print(json.dumps({
    "session_id": session_id,
    "term_program": "ghostty",
    "tmux": f"{socket},0,0",
    "tmux_pane": pane,
}))
PY
)"
}

write_question_transcript() {
  local path="$1"
  local mode="$2"
  local marker="$3"
  python3 - "$path" "$mode" "$marker" <<'PY'
import json, sys
path, mode, marker = sys.argv[1:]
if mode == "option":
    prompt = "PHONE QA option: tap the option button labelled Write option marker."
    options = [{
        "id": "write-option",
        "label": "Write option marker",
        "value": f"printf qa_option_ok > {marker}",
        "description": "Writes a marker into the captured tmux pane.",
    }]
else:
    command = f"printf qa_manual_ok > {marker}"
    prompt = f"PHONE QA manual: type exactly this and submit: {command}"
    options = []

line = {
    "message": {
        "role": "assistant",
        "model": "phone-qa",
        "content": [{
            "type": "tool_use",
            "id": f"toolu_{mode}",
            "name": "AskUserQuestion",
            "input": {
                "questions": [{
                    "id": f"qa-{mode}",
                    "question": prompt,
                    "options": options,
                }]
            },
        }],
        "usage": {
            "input_tokens": 12,
            "output_tokens": 3,
        },
    }
}
with open(path, "w", encoding="utf-8") as f:
    f.write(json.dumps(line, separators=(",", ":")) + "\n")
PY
}

create_question_session() {
  local kind="$1"
  local session_id="vbqa-$kind"
  local tmux_name="$TMUX_PREFIX-$kind"
  local transcript="$STATE_DIR/$kind.jsonl"
  local marker="$STATE_DIR/$kind-marker.txt"
  local pane
  pane="$(create_tmux_session "$tmux_name")"
  write_question_transcript "$transcript" "$kind" "$marker"
  register_terminal "$session_id" "$tmux_name" "$pane"
  post_authed_json "hook" "$(python3 - "$session_id" "$PROJECT_DIR" "$transcript" <<'PY'
import json, sys
session_id, cwd, transcript = sys.argv[1:]
print(json.dumps({
    "hook_event_name": "SessionStart",
    "session_id": session_id,
    "cwd": cwd,
    "transcript_path": transcript,
}))
PY
)"
  post_authed_json "hook" "$(python3 - "$session_id" "$PROJECT_DIR" "$transcript" "$kind" <<'PY'
import json, sys
session_id, cwd, transcript, kind = sys.argv[1:]
print(json.dumps({
    "hook_event_name": "Notification",
    "session_id": session_id,
    "cwd": cwd,
    "message": f"PHONE QA {kind}: waiting for your input",
    "transcript_path": transcript,
}))
PY
)"
}

setup_questions() {
  require curl
  require python3
  require "$(tmux_path)"
  healthcheck
  mkdir -p "$STATE_DIR"
  rm -f "$STATE_DIR"/*-marker.txt
  create_question_session option
  create_question_session manual
  cat <<EOF
Phone QA question sessions are live.

On iPhone VibeBuddy:
1. Confirm the dashboard updates without manual refresh.
2. Open "PHONE QA option" and tap "Write option marker".
3. Open "PHONE QA manual", type exactly:
   printf qa_manual_ok > $STATE_DIR/manual-marker.txt
   then submit.

Then run:
  scripts/phone_qa_harness.sh watch
EOF
}

start_approval() {
  require curl
  require python3
  healthcheck
  local session_id="vbqa-approval"
  post_authed_json "hook" "$(python3 - "$session_id" "$PROJECT_DIR" <<'PY'
import json, sys
session_id, cwd = sys.argv[1:]
print(json.dumps({
    "hook_event_name": "SessionStart",
    "session_id": session_id,
    "cwd": cwd,
}))
PY
)"
  echo "Approval started. Tap Approve or Deny on the iPhone within 25 seconds..."
  curl -fsS -X POST "$BASE_URL/approval" \
    -H "$(auth_header)" \
    -H 'Content-Type: application/json' \
    --data-binary "$(python3 - "$session_id" "$PROJECT_DIR" <<'PY'
import json, sys
session_id, cwd = sys.argv[1:]
print(json.dumps({
    "hook_event_name": "PreToolUse",
    "session_id": session_id,
    "cwd": cwd,
    "tool_name": "Edit",
    "tool_input": {
        "file_path": "Sources/PhoneQAExample.swift",
        "old_string": "let mode = \"before\"",
        "new_string": "let mode = \"after\"",
    },
}))
PY
)"
  echo
}

watch_markers() {
  require curl
  require python3
  local option_marker="$STATE_DIR/option-marker.txt"
  local manual_marker="$STATE_DIR/manual-marker.txt"
  for _ in $(seq 1 120); do
    local option="missing"
    local manual="missing"
    [[ -f "$option_marker" ]] && option="$(cat "$option_marker")"
    [[ -f "$manual_marker" ]] && manual="$(cat "$manual_marker")"
    printf 'option=%s manual=%s\n' "$option" "$manual"
    local snapshot
    snapshot="$(curl -fsS "$BASE_URL/snapshot" -H "$(auth_header)")"
    python3 -c '
import json, sys
data = json.load(sys.stdin)
for s in data.get("sessions", []):
    if s.get("id", "").startswith("vbqa-"):
        print("{} status={} wait={} approval={} question={}".format(
            s.get("id"), s.get("status"), s.get("waitKind"),
            bool(s.get("pendingApproval")), bool(s.get("pendingQuestion"))))
' <<< "$snapshot"
    if [[ "$option" == "qa_option_ok" && "$manual" == "qa_manual_ok" ]]; then
      exit 0
    fi
    sleep 1
  done
  exit 1
}

cleanup() {
  local tmux
  tmux="$(tmux_path)"
  "$tmux" kill-session -t "$TMUX_PREFIX-option" >/dev/null 2>&1 || true
  "$tmux" kill-session -t "$TMUX_PREFIX-manual" >/dev/null 2>&1 || true
  for sid in vbqa-option vbqa-manual vbqa-approval; do
    post_authed_json "hook" "$(python3 - "$sid" "$PROJECT_DIR" <<'PY'
import json, sys
sid, cwd = sys.argv[1:]
print(json.dumps({"hook_event_name":"SessionEnd","session_id":sid,"cwd":cwd}))
PY
)" || true
  done
  rm -rf "$STATE_DIR"
  echo "Phone QA harness cleaned up."
}

main() {
  case "${1:-}" in
    setup-questions) setup_questions ;;
    start-approval) start_approval ;;
    watch) watch_markers ;;
    cleanup) cleanup ;;
    *) usage; exit 2 ;;
  esac
}

main "$@"
