#!/usr/bin/env python3
"""Install/uninstall vibebuddy hooks in ~/.qwen/settings.json (Qwen Code).

Qwen Code ships native Claude-style hooks with an `http` type that POSTs the event
JSON straight to a URL; its payload already matches vibebuddy's Claude shape, so no
forwarder and no daemon change are needed — this is config only. Loopback is allowed
by qwen's SSRF guard. Terminal capture (for jump-to-terminal) reuses the shared
capture-terminal.sh as a command hook on SessionStart + UserPromptSubmit (self-heal).

Fail-open, idempotent, reversible (backs up once). Mirrors install-claude-hooks.py.

Usage:
    python3 install-qwen-hooks.py --dry-run
    python3 install-qwen-hooks.py --install
    python3 install-qwen-hooks.py --uninstall
"""
import json
import os
import shutil
import sys

SETTINGS = os.path.expanduser("~/.qwen/settings.json")
BACKUP = os.path.expanduser("~/.qwen/settings.json.vibebuddy-backup")
PORT = int(os.environ.get("VIBEBUDDY_PORT", "9876"))
# /hook is bearer-token gated (daemon-security/01). Qwen's native http hook can't
# set headers, so the token rides as a ?token= query param, read from the daemon's
# token file at install time. HOOK_MARKER (token-free) drives idempotent detect /
# uninstall, so a rotated token still matches the installed hook.
def _vibebuddy_token():
    try:
        with open(os.path.expanduser("~/Library/Application Support/vibebuddy/token")) as f:
            return f.read().strip()
    except OSError:
        return ""


HOOK_MARKER = f"http://127.0.0.1:{PORT}/hook?agent=qwen"
_TOKEN = _vibebuddy_token()
HOOK_URL = HOOK_MARKER + (f"&token={_TOKEN}" if _TOKEN else "")
CAPTURE_HOOK = os.path.join(os.path.dirname(os.path.abspath(__file__)), "capture-terminal.sh")
CAPTURE_MARKER = "capture-terminal.sh"

TOOL_EVENTS = {"PreToolUse", "PostToolUse", "PostToolUseFailure"}
# qwen fires PostToolUseFailure separately (no is_error inside PostToolUse); the
# daemon treats it as a failed tool result for the stuck cue.
EVENTS = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse",
          "PostToolUseFailure", "Stop", "SessionEnd"]
CAPTURE_EVENTS = ["SessionStart", "UserPromptSubmit"]


def http_group(event):
    # matcher is a regex on tool name for tool events; "*" matches all otherwise.
    matcher = ".*" if event in TOOL_EVENTS else "*"
    return {"matcher": matcher,
            "hooks": [{"type": "http", "url": HOOK_URL, "timeout": 5}]}


def is_vibebuddy(g):
    return isinstance(g, dict) and any(
        (HOOK_MARKER in h.get("url", "") or CAPTURE_MARKER in h.get("command", ""))
        for h in g.get("hooks", []) if isinstance(h, dict)
    )


def install(data):
    hooks = data.setdefault("hooks", {})
    added = []
    for ev in EVENTS:
        arr = hooks.setdefault(ev, [])
        if any(is_vibebuddy(g) for g in arr):
            continue
        arr.append(http_group(ev))
        added.append(ev)
    # Terminal capture (self-heal: SessionStart catches new, UserPromptSubmit re-captures).
    for ev in CAPTURE_EVENTS:
        arr = hooks.setdefault(ev, [])
        if not any(CAPTURE_MARKER in h.get("command", "")
                   for g in arr if isinstance(g, dict)
                   for h in g.get("hooks", []) if isinstance(h, dict)):
            arr.append({"hooks": [{"type": "command", "command": f'"{CAPTURE_HOOK}"', "timeout": 5000}]})
    return added


def uninstall(data):
    hooks = data.get("hooks", {})
    removed = []
    for ev in list(hooks.keys()):
        before = len(hooks[ev])
        hooks[ev] = [g for g in hooks[ev] if not is_vibebuddy(g)]
        if len(hooks[ev]) < before:
            removed.append(ev)
        if not hooks[ev]:
            del hooks[ev]
    return removed


def write(data):
    if not os.path.exists(BACKUP):
        shutil.copy2(SETTINGS, BACKUP)
        print("backup written:", BACKUP)
    with open(SETTINGS, "w") as f:
        json.dump(data, f, indent=2)
        f.write("\n")


def main():
    mode = sys.argv[1] if len(sys.argv) > 1 else "--dry-run"
    with open(SETTINGS) as f:
        data = json.load(f)

    if mode == "--uninstall":
        removed = uninstall(data)
        write(data)
        print("removed vibebuddy qwen hooks from:", removed or "(none)")
        return

    added = install(data)
    if mode == "--dry-run":
        print("would add vibebuddy qwen hooks for:", added or "(already installed)")
        print("--- hooks block (no secrets) ---")
        print(json.dumps({"hooks": data["hooks"]}, indent=2))
    elif mode == "--install":
        write(data)
        print("installed vibebuddy qwen hooks for:", added or "(already installed)")
    else:
        print("unknown mode:", mode)
        sys.exit(2)


if __name__ == "__main__":
    main()
